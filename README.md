# Building a Windows Domain Controller on AWS, Hardened, and Hybrid-Synced to Azure

A field-notes writeup of a real infrastructure build: a single Windows Server VM on AWS EC2, turned into a working Active Directory domain, hardened, right-sized twice as real workloads demanded it, stocked with Microsoft Office, populated with 25 users across proper security-group-scoped access tiers, and connected to Microsoft Entra ID via Entra Connect Sync for hybrid identity — including every real issue hit along the way and how it was diagnosed and fixed.

This is written so someone else could redo it themselves with nothing more than a terminal and patience. Every command below actually ran, in this order, on a real build.

## Table of contents

1. [Launch the virtual machine](#1-launch-the-virtual-machine)
2. [Turn on browser-based access](#2-turn-on-browser-based-access)
3. [Promote it to a domain controller](#3-promote-it-to-a-domain-controller)
4. [Right-size the hardware](#4-right-size-the-hardware)
5. [Harden the domain controller](#5-harden-the-domain-controller)
6. [Grow the disk when space runs low](#6-grow-the-disk-when-space-runs-low)
7. [Install Microsoft Office, unattended](#7-install-microsoft-office-unattended)
8. [Reach out to Azure](#8-reach-out-to-azure)
9. [Tune Windows for low RAM](#9-tune-windows-for-low-ram)
10. [Populate the directory](#10-populate-the-directory)
11. [Prove the sync actually works](#11-prove-the-sync-actually-works)
12. [Back it up automatically](#12-back-it-up-automatically)
13. [Glossary](#glossary)

---

## 1. Launch the virtual machine

A VM is a computer that exists only as software, rented by the hour from AWS instead of sitting on a desk.

**What you need first:** an AWS account with the CLI installed and signed in, and to know which region you're working in (this build used `us-east-1`).

```bash
# Find the newest Windows Server AMI instead of hunting for an ID by hand
aws ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base \
  --query 'Parameter.Value' --output text

# Create a key pair - the only copy of the private key; AWS never lets you download it again
aws ec2 create-key-pair --key-name my-vm-key --query 'KeyMaterial' --output text > my-vm-key.pem
chmod 400 my-vm-key.pem

# Security group: open RDP (3389) ONLY to your own IP, never to the whole internet
aws ec2 create-security-group --group-name my-vm-sg \
  --description "RDP restricted to my IP" --vpc-id <your-vpc-id>
aws ec2 authorize-security-group-ingress --group-id <sg-id> \
  --protocol tcp --port 3389 --cidr <your-ip>/32

# Launch on the smallest free-tier size
aws ec2 run-instances --image-id <ami-id> --instance-type t3.micro \
  --key-name my-vm-key --security-group-ids <sg-id> --subnet-id <subnet-id> \
  --count 1 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=my-vm}]'

# Once running, decrypt the Windows admin password (can take a few minutes after first boot)
aws ec2 get-password-data --instance-id <instance-id> \
  --priv-launch-key my-vm-key.pem --query PasswordData --output text
```

> **Why restrict RDP to one IP?** Port 3389 open to `0.0.0.0/0` is one of the most commonly scanned-and-attacked ports on the internet.

## 2. Turn on browser-based access

Everything from here on runs through **AWS Systems Manager (SSM)** instead of RDP — command execution from a terminal, and even browser-based Remote Desktop from the AWS Console, without ever widening the security group. It needs an IAM role attached to the instance.

```bash
aws iam create-role --role-name vm-ssm-role --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name vm-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name vm-ssm-profile
aws iam add-role-to-instance-profile --instance-profile-name vm-ssm-profile --role-name vm-ssm-role
aws ec2 associate-iam-instance-profile --instance-id <instance-id> \
  --iam-instance-profile Name=vm-ssm-profile

aws ssm describe-instance-information --filters Key=InstanceIds,Values=<instance-id>
```

> A role attached *after* the instance already booted sometimes needs a reboot before the SSM Agent notices its new permissions.

> **Important, discovered later:** if this instance is a domain controller, AWS Console's browser-based "Connect via Session Manager / Fleet Manager RDP" feature will never work — it requires creating a temporary local Windows account (`ssm-user`), and domain controllers don't have local accounts at all. Use a real RDP client instead for interactive sessions; `aws ssm send-command` for headless PowerShell still works fine.

## 3. Promote it to a domain controller

A domain is a shared identity system — one database every computer and user trusts. With only one VM, that VM becomes the domain controller (DC); creating the domain and joining it happen in the same step.

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

$secpasswd = ConvertTo-SecureString '<your-DSRM-password>' -AsPlainText -Force
Install-ADDSForest -DomainName 'yourdomain.local' `
  -DomainNetbiosName 'YOURDOMAIN' `
  -SafeModeAdministratorPassword $secpasswd `
  -InstallDns:$true -NoRebootOnCompletion:$true -Force:$true

shutdown /r /t 900   # restart on your own schedule
```

> **DSRM** (Directory Services Restore Mode) is a special recovery mode for a broken domain controller, unlocked by its own separate password. Save it somewhere safe — it's much harder to reset later than a regular password.

> Once promotion finishes, the local `Administrator` account merges into the domain. Sign in afterward as `YOURDOMAIN\Administrator` — same password, different username format.

## 4. Right-size the hardware

Active Directory wants more memory than a free-tier `t3.micro` (1GB RAM) comfortably gives it. Changing instance *type* — not just restarting Windows — needs a real stop/start cycle.

```bash
aws ec2 stop-instances --instance-ids <instance-id>
aws ec2 wait instance-stopped --instance-ids <instance-id>
aws ec2 modify-instance-attribute --instance-id <instance-id> --instance-type '{"Value": "t3.large"}'
aws ec2 start-instances --instance-ids <instance-id>
aws ec2 wait instance-running --instance-ids <instance-id>
```

Get exact pricing before committing, instead of guessing:

```bash
aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
  --filters "Type=TERM_MATCH,Field=instanceType,Value=t3.large" \
            "Type=TERM_MATCH,Field=location,Value=US East (N. Virginia)" \
            "Type=TERM_MATCH,Field=operatingSystem,Value=Windows" \
            "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
            "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
            "Type=TERM_MATCH,Field=capacitystatus,Value=Used"
```

This build went `t3.micro → t3.small → t3.large` (1GB → 2GB → 8GB) as real workloads (AD DS, then Entra Connect Sync's SQL LocalDB, then Office) stacked up.

> **A real lesson learned:** a slow VM and a failing `Install-Module -Name Az` looked like the same problem (both blamed on low memory), so the instance got upsized from 2GB to 8GB expecting it to fix both. It fixed the slowness. It did **not** fix the module install — proving that bug was never about memory at all (see section 8). Doubling hardware is a real fix for a resource ceiling; it's an expensive way to find out a bug was never about resources.

> Stopping and starting (unlike a plain reboot) usually hands the instance a new public IP, unless you've attached an Elastic IP.

## 5. Harden the domain controller

A production-grade DC needs a few things a default install doesn't apply on its own.

**Static IP & self-hosted DNS** — a DC should own a fixed address and be its own DNS server:

```powershell
$if = (Get-NetAdapter | Where Status -eq Up | Select -First 1).Name
Set-NetIPInterface -InterfaceAlias $if -Dhcp Disabled
New-NetIPAddress -InterfaceAlias $if -IPAddress 172.31.9.68 -PrefixLength 20 -DefaultGateway 172.31.0.1
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 127.0.0.1
Add-DnsServerForwarder -IPAddress 172.31.0.2   # AWS's own resolver, for internet lookups
```

**A time source everyone trusts** — Kerberos fails silently if clocks drift more than a few minutes:

```powershell
w32tm /config /manualpeerlist:"169.254.169.123" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time
w32tm /resync /force
```

**Organize accounts before you have too many to sort:**

```powershell
$dn = (Get-ADDomain).DistinguishedName
foreach ($ou in 'Servers','Workstations','Employees','Groups','Service Accounts') {
  New-ADOrganizationalUnit -Name $ou -Path $dn -ProtectedFromAccidentalDeletion $true
}
```

> **Naming gotcha:** don't name an OU `Users` or `Computers` — Active Directory already has built-in containers with those exact names, and the clash fails with "name already in use."

**Turn on the undo button** (permanent, off by default):

```powershell
Enable-ADOptionalFeature -Identity 'Recycle Bin Feature' `
  -Scope ForestOrConfigurationSet -Target 'yourdomain.local' -Confirm:$false
```

## 6. Grow the disk when space runs low

AWS can grow storage live, without turning the machine off — Windows still needs to be told to claim the new space.

```bash
aws ec2 modify-volume --volume-id <volume-id> --size 65
```

```powershell
Update-HostStorageCache
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
Resize-Partition -DriveLetter C -Size $max
```

> Check `[math]::Round((Get-PSDrive C).Free/1GB,2)` before you're desperate — anything under a couple of GB free on a low-RAM server is worth fixing before it causes a crash.

## 7. Install Microsoft Office, unattended

Office installs through a small bootstrapper and a configuration file, so it never has to stop and ask a question during setup:

```powershell
Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile 'C:\Temp\Office\setup.exe'
```

`C:\Temp\Office\configuration.xml`:
```xml
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
</Configuration>
```

```powershell
Start-Process 'C:\Temp\Office\setup.exe' -ArgumentList '/configure C:\Temp\Office\configuration.xml' -Wait
```

> This is exactly the kind of job that can quietly exhaust a small disk mid-install (see section 6) — check free space before kicking off a large install.

## 8. Reach out to Azure

AWS and Azure are separate companies with separate logins. A sign-in step can never be scripted end-to-end by someone else on your behalf — it has to be you, in your own session.

```powershell
Install-Module -Name Az -Scope CurrentUser -Force
Connect-AzAccount -AccountId "you@example.com"
New-AzResourceGroup -Name "sandbox-rg" -Location "eastus" -Tag @{ Environment = "Sandbox" }
```

### When Install-Module silently leaves modules missing

`Install-Module -Name Az -Scope CurrentUser -Force` kept reporting "success" while `Az.Accounts` and `Az.Resources` stayed missing afterward — on both a 2GB and, after resizing, an 8GB instance. Same failure either way, which ruled out memory and pointed at something the command needs but never announces it's missing: a current **NuGet provider**.

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -Verbose
```

> **Verify, don't trust the exit code.** `Install-Module` can return cleanly while quietly skipping a package that failed underneath it. Check afterward with `Get-Module -ListAvailable -Name Az.Accounts` and add `-Verbose` when something's wrong — the default output hides exactly the line that would explain it.

### A background agent silently rewrote the module search path

Even after the NuGet fix, a brand-new PowerShell window *still* reported `Az.Accounts` missing — despite the files provably existing on disk. The cause: installing the **Azure AD Connect Health Agent** (bundled with Entra Connect Sync) had overwritten this user's `PSModulePath` down to a single entry, wiping out the personal modules folder it was supposed to search.

The robust fix is to self-heal at the top of any script that depends on it, every run, since a registry fix alone doesn't guarantee a new session picks it up:

```powershell
$personalModules = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
if ($env:PSModulePath -notlike "*$personalModules*") {
    $env:PSModulePath = "$personalModules;$env:PSModulePath"
}
```

> Installing one thing can quietly break another. Nothing about the Health Agent install mentioned touching `PSModulePath` — it just did, as a side effect.

### The tenant existed. The subscription didn't.

Sign-in succeeded, module import succeeded, and then resource group creation failed anyway:

```
New-AzResourceGroup : 'this.Client.SubscriptionId' cannot be null.
```

Entra ID (identity/directory) and an actual Azure subscription (the billable container resources live in) are two separate things — a tenant can exist for months with real users in it and still have zero subscriptions attached. `Get-AzSubscription` returning an empty list, with only a bare tenant name showing, is the tell. The fix happens in the portal, by a human, since it means attaching a payment method — then refresh the session:

```powershell
Get-AzSubscription | Set-AzContext
```

**Result:** once a real subscription existed, the exact same script ran clean end to end.

### Azure AD Connect changed its distribution model

As of mid-2026, Microsoft stopped offering Azure AD Connect as a plain download. It now lives inside the **Microsoft Entra Admin Center**: sign in there, go to *Identity → Entra Connect → Entra Connect Sync*, and download it from inside the portal.

### The sign-in wall almost everyone hits first

Signing into the Entra Connect Sync wizard with a **personal Microsoft account** fails with:

```
AADSTS50020: User account '...' from identity provider 'live.com' does not
exist in tenant '' ... The account needs to be added as an external user
in the tenant first.
```

Even confirming that account genuinely holds Global Administrator doesn't help — it's represented as an **external guest** (`#EXT#`), and Entra Connect Sync flatly refuses personal accounts regardless of role. The fix: create a brand-new cloud-only user that lives *directly* in the tenant (Entra Admin Center → Identity → Users → New user), assign it **Hybrid Identity Administrator**, and sign in with that instead.

The wizard also asks for two *different* logins that are easy to conflate:

| Wizard step | Which account |
|---|---|
| Connect to Microsoft Entra | the new cloud-only tenant account |
| Connect to AD DS | the on-prem `YOURDOMAIN\Administrator` account |

A `.local` domain will also never show as a verified UPN suffix (domain verification needs a public DNS TXT record, and `.local` was never meant to touch the public internet) — check "Continue without matching all UPN suffixes to verified domains" and move on; synced accounts will sign into Azure using the tenant's own `onmicrosoft.com` suffix instead.

## 9. Tune Windows for low RAM

None of this makes the VM more powerful — it stops Windows from spending memory on things a lab server doesn't need.

| Setting | Command | Effect |
|---|---|---|
| Power plan | `powercfg /setactive SCHEME_MIN` | No CPU throttling for power you're not paying to save |
| Page file | `Win32_PageFileSetting` → 4096-8192MB fixed | A safety cushion so low RAM causes slowdowns, not crashes |
| SysMain | `Set-Service SysMain -StartupType Disabled` | Superfetch's disk pre-caching does nothing useful on cloud storage |
| Windows Search | `Set-Service WSearch -StartupType Disabled` | Frees RAM if not relying on Outlook/file search |
| Server Manager | `Disable-ScheduledTask -TaskName ServerManager` | Stops it silently relaunching every login |

## 10. Populate the directory

An empty domain proves nothing. This build created 25 accounts with a naming convention that answers its own question — a suffix says exactly what each account is for:

- `breakglass-superuser` — 1 account, Domain + Enterprise Admins (the "just in case" emergency account)
- `*-admin` — 4 accounts, Domain Admins
- `*-it` / `-finance` / `-hr` / `-sales` / `-engineering` — 5 accounts, one department-scoped security group each
- `*-readonly` — 10 accounts, one shared `GG-ReadOnly` group
- `svc-*-service` — 5 service accounts, non-expiring passwords, `GG-ServiceAccounts`

Drive creation from a table, not 25 copy-pasted blocks, and skip anything that already exists so it's safe to re-run:

```powershell
$users = @(
  @{Sam='jmartin-admin'; Given='John'; Sur='Martin'; OU=$employeesOU; Groups=@('Domain Admins')}
  @{Sam='khall-it'; Given='Kevin'; Sur='Hall'; OU=$employeesOU; Groups=@('GG-ITAccess')}
  @{Sam='svc-backup-service'; Given='SVC'; Sur='Backup'; OU=$serviceOU; Groups=@('GG-ServiceAccounts'); Service=$true}
  # ...
)

foreach ($u in $users) {
  if (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue) { continue }
  $isService = $u.ContainsKey('Service') -and $u.Service
  New-ADUser -Name "$($u.Given) $($u.Sur)" -SamAccountName $u.Sam `
    -UserPrincipalName "$($u.Sam)@yourdomain.local" -Path $u.OU `
    -AccountPassword (ConvertTo-SecureString '<a-strong-temp-password>' -AsPlainText -Force) `
    -Enabled $true -ChangePasswordAtLogon (-not $isService) -PasswordNeverExpires $isService
  foreach ($g in $u.Groups) { Add-ADGroupMember -Identity $g -Members $u.Sam }
}
```

> **A 21-character name will fail.** `SamAccountName` has a hard 20-character limit, a leftover from NetBIOS. `svc-fileshare-service` (21 chars) failed with "the name provided is not a properly formed account name"; shortening it to `svc-files-service` fixed it instantly.

> **Service accounts age differently than people.** Humans get `ChangePasswordAtLogon = $true`. Service accounts get `PasswordNeverExpires = $true`, since nothing is ever sitting at a keyboard to type a new one when it expires.

> **A computer object is not a domain controller.** Placeholder computer accounts (no real machine behind them) are fine for populating a lab directory, but dropping one into the *Domain Controllers* OU doesn't make it a real DC — that needs its own running, promoted Windows Server.

## 11. Prove the sync actually works

A clean "Configuration succeeded" screen from the wizard is not proof. Create one test object, force a sync, and go look for it on the other side:

```powershell
New-ADUser -Name 'Test User One' -SamAccountName 'testuser1' -Path $employeesOU `
  -AccountPassword (ConvertTo-SecureString '<a-strong-temp-password>' -AsPlainText -Force) -Enabled $true

Import-Module 'C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1'
Start-ADSyncSyncCycle -PolicyType Delta
```

Then check **Entra Admin Center → Identity → Users** for that name with `On-premises sync: Yes`.

If it doesn't show up right away, check the connector space directly — it tells the truth faster than the portal does:

```powershell
Get-ADSyncCSObject -ConnectorName 'yourdomain.local' `
  -DistinguishedName 'CN=Test User One,OU=Employees,DC=yourdomain,DC=local'
# ObjectType: user -> the on-prem side imported it correctly

Get-ADSyncCSObject -ConnectorName 'yourtenant.onmicrosoft.com - AAD' |
  Where-Object ObjectType -eq 'user' | Select DistinguishedName, ExportError
# ExportError blank -> no failure; it's just waiting on Microsoft's side
```

An empty `ExportError` plus a present connector-space object means the sync engine did its job — the very first object synced into a brand-new tenant can take several extra minutes to appear in the portal while Microsoft provisions hybrid-identity plumbing behind the scenes. That's a one-time delay, not a recurring one.

---

## 12. Back it up automatically

Everything built so far — the users, the groups, the OU layout, the sync configuration — lives on one disk, on one VM. A domain controller is the single copy of the account database; if it's gone, the domain is gone. Taking a snapshot by hand works right up until the day you forget. AWS Backup turns that habit into a policy: a schedule, a retention window, and an audit trail, running whether anyone remembers or not.

### Give the backup service permission to act

AWS Backup is a service, not a person, so it needs its own role. Two AWS-managed policies cover it — one for making backups, one for restoring them:

```bash
aws iam create-role --role-name AWSBackupDefaultServiceRole \
  --assume-role-policy-document file://trust.json

aws iam attach-role-policy --role-name AWSBackupDefaultServiceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup

aws iam attach-role-policy --role-name AWSBackupDefaultServiceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores
```

Where `trust.json` says "the backup service may assume this role":

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "backup.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

### Create a vault, then a plan

A vault is the container recovery points land in. Giving this server its own named vault — rather than the account's default — means retention and access rules can be set for it later without touching anything else.

```bash
aws backup create-backup-vault --backup-vault-name <your-vault-name>
```

The plan is the policy: when to run, how long to keep each copy, and how late a job may still start. Retention is the real decision — seven days covers "someone broke something on Tuesday" without paying to store months of history.

```json
{
  "BackupPlanName": "<your-plan-name>",
  "Rules": [{
    "RuleName": "daily-midnight-local",
    "TargetBackupVaultName": "<your-vault-name>",
    "ScheduleExpression": "cron(0 5 * * ? *)",
    "ScheduleExpressionTimezone": "America/Chicago",
    "StartWindowMinutes": 60,
    "CompletionWindowMinutes": 180,
    "Lifecycle": { "DeleteAfterDays": 7 }
  }]
}
```

```bash
aws backup create-backup-plan --backup-plan file://plan.json
```

> **Set `ScheduleExpressionTimezone` explicitly.** Without it the cron expression is interpreted as UTC, and the job quietly shifts by an hour twice a year when daylight saving starts and ends.

### Tell the plan what to protect

A plan on its own backs up nothing — it needs a *selection* naming the resources it applies to. Pointing at the **instance** rather than the volume captures the machine as a whole, so a restore produces a bootable server instead of a bare disk you'd have to reattach by hand.

```json
{
  "SelectionName": "<your-selection-name>",
  "IamRoleArn": "arn:aws:iam::<your-account-id>:role/AWSBackupDefaultServiceRole",
  "Resources": [
    "arn:aws:ec2:<your-region>:<your-account-id>:instance/<your-instance-id>"
  ]
}
```

```bash
aws backup create-backup-selection --backup-plan-id <your-plan-id> \
  --backup-selection file://selection.json
```

### Take one now, as a known-good baseline

The schedule protects you starting tomorrow. A one-off backup taken the moment the build is finished and working is worth keeping longer than the daily rotation — it's the point you'd actually want to return to if a later change goes wrong.

```bash
aws backup start-backup-job \
  --backup-vault-name <your-vault-name> \
  --resource-arn arn:aws:ec2:<your-region>:<your-account-id>:instance/<your-instance-id> \
  --iam-role-arn arn:aws:iam::<your-account-id>:role/AWSBackupDefaultServiceRole \
  --lifecycle DeleteAfterDays=30 \
  --recovery-point-tags Type=baseline-build-complete
```

```bash
aws backup describe-backup-job --backup-job-id <your-job-id> \
  --query '{State:State,Pct:PercentDone,Msg:StatusMessage}'
```

An EC2 backup registers an AMI first and only then snapshots the disk behind it, so `PercentDone` can legitimately read `0.0` for ten or fifteen minutes on a 65GB volume. Nothing is wrong; it just has nothing to report yet. This one took about 27 minutes end to end.

### The reported size is not the billed size

When the job finished it reported a `BackupSizeInBytes` of 69,793,218,560 — exactly the full 65GiB volume. That's the *logical* size of what was protected, not what you're charged to keep. Snapshots store only blocks that were actually written, and each one after the first stores only what changed. To measure what's really there:

```bash
SNAP=$(aws ec2 describe-images --image-ids <your-ami-id> \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)

aws ebs list-snapshot-blocks --snapshot-id $SNAP --max-results 10000
# paginate with NextToken, then: blocks x BlockSize = real stored bytes
```

On this server that came to **68,184 blocks × 512KiB = 33.3GiB** — about half the figure the job reported, and the number the bill is actually based on.

### What it costs

AWS Backup adds no surcharge for EBS; you pay the ordinary snapshot rate, $0.05 per GB-month in `us-east-1`. Combined with the measured 33.3GiB baseline and roughly 1.5GiB of daily change held for a week, that comes to about **43.8GiB, or $2.19 a month** — against $3.25 if the full 65GB were billed on every copy.

Don't take either number on faith, including this one. Both are one command away, and both change:

```bash
aws pricing get-products --service-code AmazonEC2 \
  --filters "Type=TERM_MATCH,Field=productFamily,Value=Storage Snapshot"
```

### Three things worth knowing before you rely on this

**A stopped VM is the best thing you can snapshot.** Shutting the server down overnight to save money helps here too: a snapshot of a stopped machine has no half-finished writes in it, so the AD database comes back consistent. Snapshotting a *running* domain controller is only crash-consistent — the equivalent of pulling the power cord and hoping. Scheduling the job for a time the VM is already off costs nothing and removes the problem entirely.

**Application-consistent backups need a running VM and a prepared one.** For a domain controller that *is* running at backup time, the correct answer is Windows VSS, which tells AD to flush to disk and hold still for the moment the snapshot is taken. AWS Backup supports it, but only if the `AwsVssComponents` package is installed on the instance first. Turning VSS on without it doesn't silently downgrade — the job can fail outright. Install the components before enabling the option, not after.

**Restoring a DC from a snapshot is a single-server trick.** In a one-controller domain, rolling back to a snapshot is fine. In a real domain with several controllers it causes *USN rollback*: the restored server replays update numbers its peers have already seen, they conclude it's lying, and replication with it stops. Production recovery uses an authoritative or non-authoritative restore through DSRM instead.

---

## Glossary

| Term | Meaning |
|---|---|
| VM | Virtual machine — a computer that exists as software, running on physical hardware in a data center |
| Domain | A shared identity system: one login database every computer and user in it trusts |
| Domain controller | The server holding the domain's account database, answering "who is this, and what are they allowed to do?" |
| AD DS | Active Directory Domain Services — the Windows feature that turns a plain server into a domain controller |
| DNS | The system that turns names into addresses computers can connect to |
| OU | Organizational Unit — a folder inside the domain for grouping accounts and computers |
| DSRM | Directory Services Restore Mode — recovery mode for a broken domain controller, unlocked by its own password |
| SSM | AWS Systems Manager — run commands on a VM from the CLI without an open RDP port |
| EBS volume | The virtual hard drive attached to an AWS VM, resizable on its own |
| IAM role | Permissions a VM (rather than a person) can be granted, to talk to other AWS services |
| SamAccountName | A Windows account's short logon name — capped at 20 characters (a NetBIOS legacy limit) |
| UPN | User Principal Name — the email-shaped login format (`user@domain`) for both on-prem and cloud sign-in |
| Tenant | One organization's dedicated, isolated copy of Entra ID |
| Global Administrator | The highest privilege role in an Entra ID tenant — but the wrong *kind* of account still can't use it for everything |
| #EXT# guest | How a personal Microsoft account looks once added to someone else's tenant — external, not native |
| Connector space | The sync engine's own local staging area — checking it directly answers "did this work?" faster than the portal |
| Delta sync | A sync cycle that pushes only what changed since the last run |
| Snapshot | A point-in-time copy of a disk; after the first, each stores only changed blocks |
| Recovery point | One restorable copy in a backup vault, stamped with when it was taken |
| Backup vault | The container recovery points live in, and where retention and access rules apply |
| Retention | How long a backup is kept before automatic deletion — recovery options traded against storage cost |
| Crash-consistent | A copy taken without quiescing the running software — the equivalent of pulling the power cord |
| VSS | Volume Shadow Copy Service — the Windows mechanism that briefly quiets applications so a backup captures them intact |
| USN rollback | What breaks when a DC is restored from a snapshot in a multi-controller domain: it reuses update numbers its peers already recorded, and they stop replicating with it |

---

*Written from a real build. Every command above ran, in this order. Details specific to one environment (real IPs, tenant names, account names) have been genericized for public sharing — the mechanics and the bugs are exactly as encountered.*
