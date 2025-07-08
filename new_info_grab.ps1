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
    Designed to run against any supported version of Windows and SQL Server.
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

function Get-CimOrWmiInstance {
    param(
        [string]$ClassName,
        [string]$ComputerName,
        [string]$Filter = $null
    )

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $params = @{ClassName = $ClassName; ComputerName = $ComputerName; ErrorAction = 'Stop'}
        if ($Filter) { $params.Filter = $Filter }
        return Get-CimInstance @params
    } else {
        $params = @{Class = $ClassName; ComputerName = $ComputerName; ErrorAction = 'Stop'}
        if ($Filter) { $params.Filter = $Filter }
        return Get-WmiObject @params
    }
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

# Start transcript safely
function Start-SafeTranscript {
    $logPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    try {
        Start-Transcript -Path $logPath -Force -ErrorAction Stop
    } catch {
        Write-Warning "Failed to start transcript: $_"
    }
}

# DNS resolution with fallback
function Resolve-FQDN {
    param([string]$HostName)
    try {
        $entry = Resolve-DnsName -Name $HostName -ErrorAction Stop
        return ($entry | Where-Object { $_.Type -eq 'A' }).NameHost
    } catch {
        try {
            $entry = [System.Net.Dns]::GetHostEntry($HostName)
            return $entry.HostName
        } catch {
            Write-Warning "DNS resolution failed for $HostName: $_"
            return $HostName
        }
    }
}

# Gather OS and hardware details
function Get-ServerOSInfo {
    param([string]$ComputerName)
    try {
        $os = Get-CimOrWmiInstance -ClassName Win32_OperatingSystem -ComputerName $ComputerName
        $cs = Get-CimOrWmiInstance -ClassName Win32_ComputerSystem -ComputerName $ComputerName
        $disks = Get-CimOrWmiInstance -ClassName Win32_LogicalDisk -ComputerName $ComputerName -Filter "DriveType=3"

        return [PSCustomObject]@{
            OperatingSystem   = $os.Caption
            OSVersion         = $os.Version
            OSArchitecture    = $os.OSArchitecture
            TotalMemoryGB     = [math]::Round($os.TotalVisibleMemorySize/1MB,2)
            ProcessorCount    = $cs.NumberOfProcessors
            LogicalProcessors = $cs.NumberOfLogicalProcessors
            Disks = $disks | ForEach-Object {
                [PSCustomObject]@{
                    DriveLetter = $_.DeviceID
                    FileSystem  = $_.FileSystem
                    SizeGB      = [math]::Round($_.Size/1GB,2)
                    FreeSpaceGB = [math]::Round($_.FreeSpace/1GB,2)
                }
            }
        }
    } catch {
        Write-Warning "OS/hardware error on $ComputerName: $_"
        return $null
    }
}

# Retrieve SQL Server core information and service accounts
function Get-SqlCoreInfo {
    param([string]$Server)
    try {
        $query = @"
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
 (SELECT value_in_use FROM sys.configurations WHERE name='min server memory (MB)') AS SQLMinMemoryMB,
 (SELECT service_account FROM sys.dm_server_services WHERE servicename = 'SQL Server') AS SQLServiceAccount,
 (SELECT service_account FROM sys.dm_server_services WHERE servicename = 'SQL Server Agent') AS SQLAgentServiceAccount;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "SQL core property error on $Server: $_"
        return $null
    }
}

# Database inventory
function Get-DatabaseInfo {
    param([string]$Server)
    try {
        $query = @"
SELECT d.name, d.recovery_model_desc, d.compatibility_level, d.state_desc, d.create_date,
       CONVERT(decimal(10,2), SUM(mf.size) / 128.0) AS SizeMB
FROM sys.databases d
JOIN sys.master_files mf ON d.database_id = mf.database_id
GROUP BY d.name, d.recovery_model_desc, d.compatibility_level, d.state_desc, d.create_date;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Database inventory error on $Server: $_"
        return $null
    }
}

# Agent jobs
function Get-AgentJobs {
    param([string]$Server)
    try {
        $query = @"
SELECT j.name AS JobName, j.enabled, js.next_run_date, js.next_run_time
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id;
"@
        return Invoke-SqlQuery -Server $Server -Query $query -Database 'msdb'
    } catch {
        Write-Warning "SQL Agent job query failed on $Server: $_"
        return $null
    }
}

# Server logins
function Get-Logins {
    param([string]$Server)
    try {
        $query = @"
SELECT name, type_desc, create_date, is_disabled
FROM sys.server_principals
WHERE type_desc IN ('SQL_LOGIN', 'WINDOWS_LOGIN', 'WINDOWS_GROUP');
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Logins query failed on $Server: $_"
        return $null
    }
}

# Linked servers
function Get-LinkedServers {
    param([string]$Server)
    try {
        $query = @"
SELECT name, product, provider, data_source, catalog
FROM sys.servers
WHERE is_linked = 1;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Linked servers query failed on $Server: $_"
        return $null
    }
}

# Database file details
function Get-DatabaseFileInfo {
    param([string]$Server)
    try {
        $query = @"
SELECT DB_NAME(database_id) AS DatabaseName,
       name AS LogicalName,
       physical_name AS FilePath,
       type_desc,
       size / 128.0 AS SizeMB,
       growth,
       is_percent_growth,
       max_size
FROM sys.master_files;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Database file query failed on $Server: $_"
        return $null
    }
}

# Availability group information
function Get-AvailabilityGroups {
    param([string]$Server)
    try {
        $query = @"
SELECT ag.name AS AGName,
       ar.replica_server_name AS ReplicaName,
       ars.role_desc,
       ar.availability_mode_desc,
       ars.synchronization_state_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars
       ON ar.replica_id = ars.replica_id;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "AG query failed on $Server: $_"
        return $null
    }
}

# Core configuration values
function Get-SqlConfiguration {
    param([string]$Server)
    try {
        $query = @"
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN ('max degree of parallelism','cost threshold for parallelism');
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Configuration query failed on $Server: $_"
        return $null
    }
}

# TempDB file configuration
function Get-TempDBInfo {
    param([string]$Server)
    try {
        $query = @"
SELECT name,
       physical_name,
       size/128.0 AS SizeMB,
       growth,
       is_percent_growth
FROM sys.master_files
WHERE database_id = 2;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "TempDB query failed on $Server: $_"
        return $null
    }
}

# Backup history (last 30 days)
function Get-BackupHistory {
    param([string]$Server)
    try {
        $query = @"
SELECT database_name,
       MAX(CASE WHEN type='D' THEN backup_finish_date END) AS LastFullBackup,
       MAX(CASE WHEN type='L' THEN backup_finish_date END) AS LastLogBackup
FROM msdb.dbo.backupset
WHERE backup_finish_date > DATEADD(day,-30,GETDATE())
GROUP BY database_name;
"@
        return Invoke-SqlQuery -Server $Server -Query $query -Database 'msdb'
    } catch {
        Write-Warning "Backup history query failed on $Server: $_"
        return $null
    }
}

# Server role membership
function Get-ServerRoles {
    param([string]$Server)
    try {
        $query = @"
SELECT sp.name AS LoginName,
       sr.name AS RoleName
FROM sys.server_role_members rm
JOIN sys.server_principals sp ON rm.member_principal_id = sp.principal_id
JOIN sys.server_principals sr ON rm.role_principal_id = sr.principal_id;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Server role query failed on $Server: $_"
        return $null
    }
}

# Wait statistics
function Get-WaitStats {
    param([string]$Server)
    try {
        $query = @"
SELECT TOP 20 wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_os_wait_stats
ORDER BY wait_time_ms DESC;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Wait stats query failed on $Server: $_"
        return $null
    }
}

# Network info (port)
function Get-SqlNetworkInfo {
    param([string]$Server)
    try {
        $query = @"
SELECT local_net_address, local_tcp_port
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Network info query failed on $Server: $_"
        return $null
    }
}

# Basic replication configuration
function Get-ReplicationInfo {
    param([string]$Server)
    try {
        $query = @"
SELECT name,
       is_published,
       is_subscribed,
       is_distributor
FROM sys.databases
WHERE is_published = 1 OR is_subscribed = 1 OR is_distributor = 1;
"@
        return Invoke-SqlQuery -Server $Server -Query $query
    } catch {
        Write-Warning "Replication query failed on $Server: $_"
        return $null
    }
}

# Retrieve SPNs for a service account
function Get-SPNInfo {
    param([string]$Account)
    try {
        $spns = setspn -L $Account 2>$null
        return $spns
    } catch {
        Write-Warning "SPN query failed for $Account: $_"
        return $null
    }
}

$AllServerData = @()

Start-SafeTranscript

foreach ($sv in $TargetServers) {
    Write-Host "`n===== Processing $sv =====" -ForegroundColor Cyan

    $hostOnly   = $sv.Split('\\')[0]
    $instance   = if ($sv -match '\\') { $sv.Split('\\')[1] } else { 'MSSQLSERVER' }

    $obj = [PSCustomObject]@{
        ScannedServerInput     = $sv
        CollectionTimestamp    = (Get-Date).ToString('s')
        Status                 = 'Pending'
        FQDN                   = Resolve-FQDN $hostOnly
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
        SQLConfig              = @()
        TempDBInfo             = @()
        AvailabilityGroups     = @()
        ReplicationInfo        = @()
        NetworkInfo            = @()
        SPNInfo                = @()
        BackupHistory          = @()
        ServerRoles            = @()
        WaitStats              = @()
        DatabaseFiles          = @()
        Databases              = @()
        AgentJobs              = @()
        Logins                 = @()
        LinkedServers          = @()
    }

    try {
        $osInfo = Get-ServerOSInfo -ComputerName $hostOnly
        if ($osInfo) {
            $obj.OperatingSystem   = $osInfo.OperatingSystem
            $obj.OSVersion         = $osInfo.OSVersion
            $obj.OSArchitecture    = $osInfo.OSArchitecture
            $obj.TotalMemoryGB     = $osInfo.TotalMemoryGB
            $obj.ProcessorCount    = $osInfo.ProcessorCount
            $obj.LogicalProcessors = $osInfo.LogicalProcessors
            $obj.Disks             = $osInfo.Disks
        }

        $core = Get-SqlCoreInfo -Server $sv
        if ($core) {
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
            $obj.SQLServiceAccount     = $core.SQLServiceAccount
            $obj.SQLAgentServiceAccount = $core.SQLAgentServiceAccount
            $spns = Get-SPNInfo -Account $core.SQLServiceAccount
            if ($spns) { $obj.SPNInfo = $spns }
        }

        $obj.NetworkInfo = Get-SqlNetworkInfo -Server $sv

        $cfg = Get-SqlConfiguration -Server $sv
        if ($cfg) { $obj.SQLConfig = $cfg | Select-Object * }

        $temp = Get-TempDBInfo -Server $sv
        if ($temp) { $obj.TempDBInfo = $temp | Select-Object * }

        $files = Get-DatabaseFileInfo -Server $sv
        if ($files) { $obj.DatabaseFiles = $files | Select-Object * }

        $ags = Get-AvailabilityGroups -Server $sv
        if ($ags) { $obj.AvailabilityGroups = $ags | Select-Object * }

        $rep = Get-ReplicationInfo -Server $sv
        if ($rep) { $obj.ReplicationInfo = $rep | Select-Object * }

        $back = Get-BackupHistory -Server $sv
        if ($back) { $obj.BackupHistory = $back | Select-Object * }

        $roles = Get-ServerRoles -Server $sv
        if ($roles) { $obj.ServerRoles = $roles | Select-Object * }

        $waits = Get-WaitStats -Server $sv
        if ($waits) { $obj.WaitStats = $waits | Select-Object * }

        $dbs = Get-DatabaseInfo -Server $sv
        if ($dbs) {
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
        }

        $jobs = Get-AgentJobs -Server $sv
        if ($jobs) { $obj.AgentJobs = $jobs | Select-Object * }

        $logins = Get-Logins -Server $sv
        if ($logins) { $obj.Logins = $logins | Select-Object * }

        $links = Get-LinkedServers -Server $sv
        if ($links) { $obj.LinkedServers = $links | Select-Object * }

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
        $jsonPath = Join-Path $PSScriptRoot "SQLInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        if ("Newtonsoft.Json.JsonConvert" -as [type]) {
            $jsonOutput = [Newtonsoft.Json.JsonConvert]::SerializeObject($AllServerData, [Newtonsoft.Json.Formatting]::Indented)
        } else {
            $jsonOutput = $AllServerData | ConvertTo-Json -Depth 10
        }
        $jsonOutput | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host "✅ JSON export completed at $jsonPath"
    } catch {
        Write-Warning "JSON export failed: $_"
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
