# Connect-Azure-Sandbox.ps1
#
# Run this from an interactive RDP session on your domain controller.
# It will open an interactive Azure sign-in prompt (browser or device code) - enter your own
# Azure credentials there. This script never stores or transmits your password.
#
# IMPORTANT: The Az module install below can take several minutes (100+ submodules).
# Do NOT close this window or press Ctrl+C while it's installing - let it run to completion.

$AzureAccountId = "youradmin@yourtenant.onmicrosoft.com"
$SandboxResourceGroup = "sandbox-rg"
$SandboxLocation = "eastus"

# --- Fix: the Azure AD Connect Health Agent overwrites this user's PSModulePath, ---
# --- wiping out the personal modules folder. Restore it for THIS session, always. ---
$personalModules = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
if ($env:PSModulePath -notlike "*$personalModules*") {
    $env:PSModulePath = "$personalModules;$env:PSModulePath"
    Write-Host "Restored personal modules folder to PSModulePath for this session." -ForegroundColor Yellow
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Install Az for the CURRENT interactive user (separate from the system-wide copy) ---
$needed = 'Az.Accounts', 'Az.Resources'
$missing = $needed | Where-Object { -not (Get-Module -ListAvailable -Name $_) }

if ($missing) {
    Write-Host "Installing Az PowerShell module for current user (this takes several minutes - let it finish)..." -ForegroundColor Cyan
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -Confirm:$false

    $stillMissing = $needed | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($stillMissing) {
        Write-Host "Install did not complete successfully. Still missing: $($stillMissing -join ', ')" -ForegroundColor Red
        Write-Host "Try running this script again without interrupting it." -ForegroundColor Yellow
        throw "Az module install incomplete - see message above."
    }
    Write-Host "Az module installed successfully." -ForegroundColor Green
} else {
    Write-Host "Az module already installed for this user." -ForegroundColor Green
}

Import-Module Az.Accounts, Az.Resources -ErrorAction Stop

Write-Host "Signing in to Azure as $AzureAccountId ..." -ForegroundColor Cyan
Write-Host "A browser window (or device code prompt) will open - complete sign-in there." -ForegroundColor Yellow
Connect-AzAccount -AccountId $AzureAccountId

Write-Host ""
Write-Host "Available subscriptions:" -ForegroundColor Cyan
Get-AzSubscription | Format-Table Name, Id, State -AutoSize

$ctx = Get-AzContext
Write-Host "Using subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Green

# --- Create sandbox resource group (free - just a container, no billable resources) ---
$existing = Get-AzResourceGroup -Name $SandboxResourceGroup -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Host "Creating sandbox resource group '$SandboxResourceGroup' in $SandboxLocation ..." -ForegroundColor Cyan
    New-AzResourceGroup -Name $SandboxResourceGroup -Location $SandboxLocation -Tag @{
        Environment = "Sandbox"
        Owner       = $AzureAccountId
        Source      = "domain-controller"
    }
} else {
    Write-Host "Resource group '$SandboxResourceGroup' already exists." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Sandbox resource group ready: $SandboxResourceGroup" -ForegroundColor Green
Write-Host "Deploy test resources into this group as needed (e.g. a test VM, storage account, VNet)." -ForegroundColor Cyan
Write-Host "Everything in this group is a normal billable Azure resource once you add anything beyond the empty group itself." -ForegroundColor Yellow
