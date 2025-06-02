# 📊 SQL Server Inventory Script

> A whimsical yet powerful PowerShell script to extract detailed configuration and resource information from SQL Server 2017 instances on Windows Server 2016/2019.

---

## 🧙‍♂️ Features

✨ This magical inventory script:

* 🔍 Gathers OS & hardware specs
* 💾 Captures disk configuration and memory stats
* 🛠 Extracts SQL Server core settings
* 🗄️ Enumerates databases with sizes and recovery models
* ⏰ Lists SQL Agent jobs and schedules
* 🧑‍🚀 Details logins and linked servers
* 🌐 Outputs in JSON (with support for deeply nested data) or CSV

---

## 🎮 Pixel Art Moment

```
        .----.
     _.'__    `.
 .--(#)(##)---/#\
' @          /###\
`--..__..-''\###/
           \#/   [SQL Inventory Wizard]
```

---

## 🚀 Requirements

* PowerShell 5.1+
* SqlServer PowerShell module

Install the SqlServer module (if not installed):

```powershell
Install-Module SqlServer -Scope CurrentUser -Force
```

---

## 🧪 Example Usage

```powershell
./Get-SQLServerInventory.ps1 -TargetServers "SQLSRV01","SQLSRV02\SQLEXPRESS" -OutputFormat Json
```

---

## 🔐 Encryption & Trust

This script uses encrypted connections with:

```powershell
Encrypt=True; TrustServerCertificate=True
```

ensuring SQL Server 2017 and older TLS configurations are fully supported.

---

## 🧠 Output Format Options

* `Json` (default): Outputs deeply structured JSON (up to 20 levels deep)
* `Csv`: Tabular summary of server-level metadata
* `None`: Just view results in the console

---

## 🧵 Structure of Output

Each server object contains:

* OS info
* CPU/Memory stats
* Disk array
* SQL version, edition, service accounts
* Database inventory
* Agent Jobs
* Logins
* Linked Servers

---

## 🧼 File Output Examples

* `SQLInventory_20250602_105304.json`
* `SQLInventory_20250602_105304.csv`
* `SQLInventory_20250602_105304.log`

---

## 🧙‍♀️ Contributor

Crafted with ✨ by **[tsvb](https://github.com/tsvb)**

---

## 🐛 Issues

If you encounter a bug or have a suggestion, [open an issue](https://github.com/tsvb/SQL_Info/issues).

---

## ⚖️ License

MIT License. Use it, fork it, customize it. Just don’t sell it to goblins 🐲.

---

## 🖼 Bonus Pixel Art

```
  .-.
 (o o)
 | O \
  \   \     SQL
   `~~~'   Inventory
```

Stay whimsical. Audit responsibly. 🪄
