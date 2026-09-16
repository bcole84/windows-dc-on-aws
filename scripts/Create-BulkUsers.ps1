$ErrorActionPreference = 'Stop'
$domainDN = (Get-ADDomain).DistinguishedName
$employeesOU = "OU=Employees,$domainDN"
$serviceOU = "OU=Service Accounts,$domainDN"
$groupsOU = "OU=Groups,$domainDN"

$stdPassword = ConvertTo-SecureString '<a-strong-temp-password>' -AsPlainText -Force
$svcPassword = ConvertTo-SecureString '<a-different-strong-password>' -AsPlainText -Force

$groups = 'GG-SuperUsers','GG-ITAccess','GG-FinanceAccess','GG-HRAccess','GG-SalesAccess','GG-EngineeringAccess','GG-ReadOnly','GG-ServiceAccounts'
foreach ($g in $groups) {
  if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
    New-ADGroup -Name $g -GroupScope Global -GroupCategory Security -Path $groupsOU
    Write-Host "Created group: $g"
  } else {
    Write-Host "Group already exists: $g"
  }
}

# One row per account. A suffix on the name says exactly what tier of access it has:
# -admin (Domain Admins), -it/-finance/-hr/-sales/-engineering (one dept group each),
# -readonly (shared read-only group), svc-*-service (non-expiring service accounts).
$users = @(
  @{Sam='jmartin-admin'; Given='John'; Sur='Martin'; OU=$employeesOU; Groups=@('Domain Admins')}
  @{Sam='swilson-admin'; Given='Sarah'; Sur='Wilson'; OU=$employeesOU; Groups=@('Domain Admins')}
  @{Sam='rthompson-admin'; Given='Robert'; Sur='Thompson'; OU=$employeesOU; Groups=@('Domain Admins')}
  @{Sam='agarcia-admin'; Given='Ana'; Sur='Garcia'; OU=$employeesOU; Groups=@('Domain Admins')}
  @{Sam='breakglass-superuser'; Given='Break'; Sur='Glass'; OU=$employeesOU; Groups=@('Domain Admins','Enterprise Admins','GG-SuperUsers')}
  @{Sam='khall-it'; Given='Kevin'; Sur='Hall'; OU=$employeesOU; Groups=@('GG-ITAccess')}
  @{Sam='bwhite-finance'; Given='Beth'; Sur='White'; OU=$employeesOU; Groups=@('GG-FinanceAccess')}
  @{Sam='tlee-hr'; Given='Tina'; Sur='Lee'; OU=$employeesOU; Groups=@('GG-HRAccess')}
  @{Sam='sking-sales'; Given='Steve'; Sur='King'; OU=$employeesOU; Groups=@('GG-SalesAccess')}
  @{Sam='dyoung-engineering'; Given='Dana'; Sur='Young'; OU=$employeesOU; Groups=@('GG-EngineeringAccess')}
  @{Sam='apatel-readonly'; Given='Amir'; Sur='Patel'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='bnguyen-readonly'; Given='Bao'; Sur='Nguyen'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='cjackson-readonly'; Given='Chloe'; Sur='Jackson'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='dclark-readonly'; Given='Derek'; Sur='Clark'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='elewis-readonly'; Given='Ella'; Sur='Lewis'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='fwalker-readonly'; Given='Finn'; Sur='Walker'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='gharris-readonly'; Given='Grace'; Sur='Harris'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='hcarter-readonly'; Given='Henry'; Sur='Carter'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='iyoung-readonly'; Given='Ivy'; Sur='Young'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='jking-readonly'; Given='Jack'; Sur='King'; OU=$employeesOU; Groups=@('GG-ReadOnly')}
  @{Sam='svc-backup-service'; Given='SVC'; Sur='Backup'; OU=$serviceOU; Groups=@('GG-ServiceAccounts'); Service=$true}
  @{Sam='svc-sql-service'; Given='SVC'; Sur='SQL'; OU=$serviceOU; Groups=@('GG-ServiceAccounts'); Service=$true}
  @{Sam='svc-webapp-service'; Given='SVC'; Sur='WebApp'; OU=$serviceOU; Groups=@('GG-ServiceAccounts'); Service=$true}
  @{Sam='svc-monitor-service'; Given='SVC'; Sur='Monitor'; OU=$serviceOU; Groups=@('GG-ServiceAccounts'); Service=$true}
  @{Sam='svc-files-service'; Given='SVC'; Sur='FileShare'; OU=$serviceOU; Groups=@('GG-ServiceAccounts'); Service=$true}
)

Write-Host "Total users to create: $($users.Count)"
$created = 0
$skipped = 0

foreach ($u in $users) {
  if (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue) {
    Write-Host "SKIP (exists): $($u.Sam)"
    $skipped++
    continue
  }
  $isService = $u.ContainsKey('Service') -and $u.Service
  $pw = if ($isService) { $svcPassword } else { $stdPassword }
  $params = @{
    Name = "$($u.Given) $($u.Sur)"
    SamAccountName = $u.Sam
    UserPrincipalName = "$($u.Sam)@yourdomain.local"
    GivenName = $u.Given
    Surname = $u.Sur
    Path = $u.OU
    AccountPassword = $pw
    Enabled = $true
    ChangePasswordAtLogon = (-not $isService)
    PasswordNeverExpires = $isService
  }
  New-ADUser @params
  foreach ($g in $u.Groups) {
    Add-ADGroupMember -Identity $g -Members $u.Sam
  }
  Write-Host "Created: $($u.Sam) -> $($u.Groups -join ', ')"
  $created++
}

Write-Host "Created: $created  Skipped: $skipped"

# --- Placeholder DC-style computer objects (NOT real domain controllers - just directory records) ---
$dcOU = "OU=Domain Controllers,$domainDN"
$placeholderDCs = 'DC02','DC03','DC04'
foreach ($dc in $placeholderDCs) {
  if (-not (Get-ADComputer -Filter "Name -eq '$dc'" -ErrorAction SilentlyContinue)) {
    New-ADComputer -Name $dc -SamAccountName $dc -Path $dcOU -Enabled $true -Description 'Placeholder only - not a real, functioning domain controller'
    Write-Host "Created placeholder DC object: $dc"
  } else {
    Write-Host "Already exists: $dc"
  }
}

# --- 10 computer objects: 7 workstations + 3 member servers ---
$serversOU = "OU=Servers,$domainDN"
$workstationsOU = "OU=Workstations,$domainDN"
$computers = @(
  @{Name='WKS-FINANCE01'; OU=$workstationsOU}
  @{Name='WKS-FINANCE02'; OU=$workstationsOU}
  @{Name='WKS-HR01'; OU=$workstationsOU}
  @{Name='WKS-SALES01'; OU=$workstationsOU}
  @{Name='WKS-SALES02'; OU=$workstationsOU}
  @{Name='WKS-ENG01'; OU=$workstationsOU}
  @{Name='WKS-IT01'; OU=$workstationsOU}
  @{Name='SRV-FILE01'; OU=$serversOU}
  @{Name='SRV-PRINT01'; OU=$serversOU}
  @{Name='SRV-APP01'; OU=$serversOU}
)
foreach ($c in $computers) {
  if (-not (Get-ADComputer -Filter "Name -eq '$($c.Name)'" -ErrorAction SilentlyContinue)) {
    New-ADComputer -Name $c.Name -SamAccountName $c.Name -Path $c.OU -Enabled $true
    Write-Host "Created computer object: $($c.Name)"
  } else {
    Write-Host "Already exists: $($c.Name)"
  }
}

Write-Host "--- Triggering delta sync to push new users to Entra ID ---"
Import-Module 'C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1'
Start-ADSyncSyncCycle -PolicyType Delta

Write-Output 'BULK_USER_CREATION_COMPLETE'
