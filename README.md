# SQL Server Inventory Script


A PowerShell script that gathers configuration and resource information from SQL Server instances on any supported version of Windows or SQL Server.


---

## Features

* Gather operating system and hardware details
* Capture disk configuration and memory statistics
* Extract SQL Server settings and core configuration (MAXDOP, CTFP)
* Enumerate databases with sizes and recovery models
* Capture database file locations and TempDB configuration
* List SQL Agent jobs and schedules
* Record logins, server roles, and linked servers
* Gather availability group and replication details
* Record recent backup history
* Collect network port and SPN information
* Capture wait statistics for baseline analysis
* Output results in JSON (supports deep nesting) or CSV

---

## Requirements

* PowerShell 5.1 or later
* `SqlServer` PowerShell module

Install the module if it is not already present:

```powershell
Install-Module SqlServer -Scope CurrentUser -Force
```

---

## Example Usage

```powershell
./new_info_grab.ps1 -TargetServers "SQLSRV01","SQLSRV02\SQLEXPRESS" -OutputFormat Json
```

---

## Encryption

The script connects using the following parameters:

```powershell
Encrypt=True; TrustServerCertificate=True
```

These settings ensure compatibility across SQL Server versions and TLS configurations.

---

## Output Format Options

* `Json` (default) – structured JSON output (up to 20 levels deep)
* `Csv` – tabular summary of server metadata
* `None` – view results in the console only

---

## Output Structure

Each server object includes:

* OS information
* CPU and memory statistics
* Disk array details
* SQL version, edition, and service accounts
* SQL configuration values
* Network port and SPN info
* Database inventory and file locations
* TempDB configuration
* Availability groups and replication status
* Backup history
* Server roles and logins
* Agent jobs
* Linked servers
* Wait statistics

---

## File Output Examples

* `SQLInventory_20250602_105304.json`
* `SQLInventory_20250602_105304.csv`
* `SQLInventory_20250602_105304.log`

---

## Contributor

Created by **[tsvb](https://github.com/tsvb)**

---

## Issues

If you encounter a bug or have a suggestion, please [open an issue](https://github.com/tsvb/SQL_Info/issues).

---

## License

This project is released under the MIT License.
