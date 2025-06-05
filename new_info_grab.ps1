<#
.SYNOPSIS
    Gathers inventory information for SQL Server instances for migration planning.

.DESCRIPTION
    This script collects OS, hardware, SQL Server instance configuration,
    database details, and migration-specific metrics (file paths, configs,
    AG info, I/O stats). Output can be JSON or CSV.

.PARAMETER TargetServers
    An array of server names (or IP addresses) to inventory.
    For named instances use "ServerName\InstanceName".

.PARAMETER OutputFormat
    'Json' (default) | 'Csv' | 'None'. Determines final export format.

.EXAMPLE
    .\new_info_grab.ps1 -TargetServers "SQLSRV01","SQLSRV02\SQLEXPRESS" -OutputFormat Json

.NOTES
    Compatible with SQL Server 2017 and Windows Server 2016/2019.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $TargetServers,

    [Parameter()]
    [ValidateSet('Json','Csv','None')]
    [string] $OutputFormat = 'Json'
)

Import-Module SqlServer -ErrorAction SilentlyContinue
if (-not (Get-Module SqlServer)) {
    Write-Warning "SqlServer module not loaded. Install with 'Install-Module SqlServer'."
    return
}

function Invoke-SqlQuery {
    param (
        [string]$Server,
        [string]$Query,
        [string]$Database = "master"
    )

    $connStr = "Server=$Server;Database=$Database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
    return Invoke-Sqlcmd -ConnectionString $connStr -Query $Query -ErrorAction Stop
}

$AllServerData = @()

$logPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logPath -Force

foreach ($sv in $TargetServers) {
    Write-Host "`n===== Processing $sv =====" -ForegroundColor Cyan

    $hostOnly   = $sv.Split('\\')[0]
    $instance   = if ($sv -match '\\') { $sv.Split('\\')[1] } else { 'MSSQLSERVER' }

    $obj = [PSCustomObject]@{
        ScannedServerInput     = $sv
        CollectionTimestamp    = (Get-Date).ToString('s')
        Status                 = 'Pending'
        FQDN                   = ''
        OperatingSystem        = ''
        OSVersion              = ''
        OSArchitecture         = ''
        TotalMemoryGB          = 0
        ProcessorCount         = 0
        LogicalProcessors      = 0
        VMwareToolsVersion     = 'N/A'
        Disks                  = @()
        SQLServerName          = ''
        SQLInstanceName        = $instance
        SQLEdition             = ''
        SQLVersion             = ''
        SQLProductLevel        = ''
        SQLProductUpdateLevel  = ''
        SQLCollation           = ''
        SQLAuthMode            = ''
        SQLMaxMemoryMB         = 0
        SQLMinMemoryMB         = 0
        SQLServiceAccount      = ''
        SQLAgentServiceAccount = ''
        FileLocations          = @()
        SQLConfig              = @()
        AvailabilityGroups     = @()
        IOStats                = @()
        Databases              = @()
        AgentJobs              = @()
        Logins                 = @()
        LinkedServers          = @()
    }

    try {
        try {
            $fqdna = Resolve-DnsName -Name $hostOnly -ErrorAction SilentlyContinue
            $obj.FQDN = if ($fqdna) { $fqdna.NameHost } else { $hostOnly }

            $os = Get-CimInstance Win32_OperatingSystem -ComputerName $hostOnly -ErrorAction Stop
            $obj.OperatingSystem   = $os.Caption
            $obj.OSVersion         = $os.Version
            $obj.OSArchitecture    = $os.OSArchitecture
            $obj.TotalMemoryGB     = [math]::Round($os.TotalVisibleMemorySize/1MB,2)

            $cs = Get-CimInstance Win32_ComputerSystem -ComputerName $hostOnly -ErrorAction Stop
            $obj.ProcessorCount    = $cs.NumberOfProcessors
            $obj.LogicalProcessors = $cs.NumberOfLogicalProcessors

            $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ComputerName $hostOnly -ErrorAction Stop
            $obj.Disks = $disks | ForEach-Object {
                [PSCustomObject]@{
                    DriveLetter = $_.DeviceID
                    FileSystem  = $_.FileSystem
                    SizeGB      = [math]::Round($_.Size/1GB,2)
                    FreeSpaceGB = [math]::Round($_.FreeSpace/1GB,2)
                }
            }
        } catch {
            Write-Warning "OS/hardware error on $($sv): $($_)"
        }

        try {
            $coreQuery = @"
SELECT
  SERVERPROPERTY('MachineName') AS SQLServerName,
  ISNULL(SERVERPROPERTY('InstanceName'),'MSSQLSERVER') AS SQLInstanceName,
  SERVERPROPERTY('Edition') AS SQLEdition,
  SERVERPROPERTY('ProductVersion') AS SQLVersion,
  SERVERPROPERTY('ProductLevel') AS SQLProductLevel,
  SERVERPROPERTY('ProductUpdateLevel') AS SQLProductUpdateLevel,
  SERVERPROPERTY('Collation') AS SQLCollation,
  CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'Windows' ELSE 'Mixed' END AS SQLAuthMode,
  (SELECT value_in_use FROM sys.configurations WHERE name='max server memory (MB)') AS SQLMaxMemoryMB,
  (SELECT value_in_use FROM sys.configurations WHERE name='min server memory (MB)') AS SQLMinMemoryMB;
"@
            $core = Invoke-SqlQuery -Server $sv -Query $coreQuery
            $obj.SQLServerName         = $core.SQLServerName
            $obj.SQLInstanceName       = $core.SQLInstanceName
            $obj.SQLEdition            = $core.SQLEdition
            $obj.SQLVersion            = $core.SQLVersion
            $obj.SQLProductLevel       = $core.SQLProductLevel
            $obj.SQLProductUpdateLevel = $core.SQLProductUpdateLevel
            $obj.SQLCollation          = $core.SQLCollation
            $obj.SQLAuthMode           = $core.SQLAuthMode
            $obj.SQLMaxMemoryMB        = $core.SQLMaxMemoryMB
            $obj.SQLMinMemoryMB        = $core.SQLMinMemoryMB

            $svcQuery = @"
SELECT servicename, startup_type_desc, status_desc, service_account
FROM sys.dm_server_services;
"@
            $svc = Invoke-SqlQuery -Server $sv -Query $svcQuery
            foreach ($r in $svc) {
                if ($r.servicename -like '*SQL Server*') {
                    $obj.SQLServiceAccount = $r.service_account
                }
                elseif ($r.servicename -like '*SQL Server Agent*') {
                    $obj.SQLAgentServiceAccount = $r.service_account
                }
            }
        } catch {
            Write-Warning "SQL core property error on $($sv): $($_)"
        }

        try {
            $dbQuery = @"
SELECT d.name, d.recovery_model_desc, d.compatibility_level, d.state_desc, d.create_date,
       CONVERT(decimal(10,2), SUM(mf.size) / 128.0) AS SizeMB
FROM sys.databases d
JOIN sys.master_files mf ON d.database_id = mf.database_id
GROUP BY d.name, d.recovery_model_desc, d.compatibility_level, d.state_desc, d.create_date;
"@
            $dbs = Invoke-SqlQuery -Server $sv -Query $dbQuery
            foreach ($db in $dbs) {
                $obj.Databases += [PSCustomObject]@{
                    Name            = $db.name
                    RecoveryModel   = $db.recovery_model_desc
                    Compatibility   = $db.compatibility_level
                    Status          = $db.state_desc
                    Created         = $db.create_date
                    SizeMB          = $db.SizeMB
                }
            }
        } catch {
            Write-Warning "Database inventory error on $($sv): $($_)"
        }

        try {
            $jobQuery = @"
SELECT j.name AS JobName, j.enabled, js.next_run_date, js.next_run_time
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id;
"@
            $obj.AgentJobs = Invoke-SqlQuery -Server $sv -Query $jobQuery -Database 'msdb' | Select-Object *
        } catch {
            Write-Warning "SQL Agent job query failed on $($sv): $($_)"
        }

        try {
            $loginQuery = @"
SELECT name, type_desc, create_date, is_disabled
FROM sys.server_principals
WHERE type_desc IN ('SQL_LOGIN', 'WINDOWS_LOGIN', 'WINDOWS_GROUP');
"@
            $obj.Logins = Invoke-SqlQuery -Server $sv -Query $loginQuery | Select-Object *
        } catch {
            Write-Warning "Logins query failed on $($sv): $($_)"
        }

        try {
            $linkedQuery = @"
SELECT name, product, provider, data_source, catalog
FROM sys.servers
WHERE is_linked = 1;
"@
            $obj.LinkedServers = Invoke-SqlQuery -Server $sv -Query $linkedQuery | Select-Object *
        } catch {
            Write-Warning "Linked servers query failed on $($sv): $($_)"
        }

        $obj.Status = 'Success'
    } catch {
        Write-Warning "General error on $($sv): $($_)"
        $obj.Status = "Error: $($_)"
    }

    $AllServerData += $obj
    Write-Host "===== Completed $sv =====`n" -ForegroundColor Green
}

Stop-Transcript
if ($OutputFormat -eq 'Json') {
    try {
        Add-Type -AssemblyName 'System.Web.Extensions' -ErrorAction SilentlyContinue
        if (-not ("Newtonsoft.Json.JsonConvert" -as [type])) {
            $jsonDll = Get-ChildItem "$env:USERPROFILE\Documents\PowerShell\Modules" -Recurse -Filter "Newtonsoft.Json.dll" | Select-Object -First 1
            if ($jsonDll) {
                Add-Type -Path $jsonDll.FullName
            } else {
                Write-Warning "Newtonsoft.Json.dll not found. Falling back to ConvertTo-Json."
                $jsonOutput = $AllServerData | ConvertTo-Json -Depth 20
                $jsonPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
                $jsonOutput | Out-File -FilePath $jsonPath -Encoding UTF8
                Write-Host "✅ JSON export completed using ConvertTo-Json at $jsonPath"
                return
            }
        }

        if ("Newtonsoft.Json.JsonConvert" -as [type]) {
            $settings = New-Object Newtonsoft.Json.JsonSerializerSettings
            $settings.ReferenceLoopHandling = "Ignore"
            $settings.MaxDepth = 256
            $settings.Formatting = [Newtonsoft.Json.Formatting]::Indented

            $jsonOutput = [Newtonsoft.Json.JsonConvert]::SerializeObject($AllServerData, $settings)
            $jsonPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $jsonOutput | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-Host "✅ JSON export completed using Newtonsoft at $jsonPath"
        } else {
            $jsonOutput = $AllServerData | ConvertTo-Json -Depth 20
            $jsonPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $jsonOutput | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-Host "✅ JSON export completed using ConvertTo-Json at $jsonPath"
        }
    } catch {
        Write-Warning "Newtonsoft JSON serialization failed: $_"
        $jsonOutput = $AllServerData | ConvertTo-Json -Depth 20
        $jsonPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $jsonOutput | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host "✅ JSON export completed using ConvertTo-Json at $jsonPath"
    }
}
elseif ($OutputFormat -eq 'Csv') {
    try {
        $csvPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $AllServerData |
            Select-Object ScannedServerInput, FQDN, OperatingSystem, OSVersion, OSArchitecture,
                          TotalMemoryGB, ProcessorCount, LogicalProcessors,
                          SQLServerName, SQLInstanceName, SQLEdition, SQLVersion,
                          SQLProductLevel, SQLProductUpdateLevel, SQLCollation,
                          SQLAuthMode, SQLMaxMemoryMB, SQLMinMemoryMB,
                          SQLServiceAccount, SQLAgentServiceAccount |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "✅ CSV export completed at $csvPath"
    } catch {
        Write-Warning "CSV export failed: $_"
    }
}

Write-Output $AllServerData
