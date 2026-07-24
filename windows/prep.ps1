# One-time first-boot prep for the GOLDEN TEMPLATE only (Windows equivalent of
# cloud-init/prep-userdata.yaml). Runs once via autounattend FirstLogonCommands,
# then sysprep /generalize powers the VM off so build-template.sh can mark it
# as a template.
#
# What it does:
#   - Installs VMware Tools (guestinfo access + vmxnet3/pvscsi drivers)
#   - Installs the OpenSSH Server capability (deploys enable the service)
#   - Installs Cloudbase-Init and points it at the VMware guestinfo datasource,
#     so clones read the SAME guestinfo.* keys Linux clones read with cloud-init
#   - Generalizes (sysprep) so every clone gets a unique identity
#
# @DEFAULT_USERNAME@ / @ADMIN_GROUP@ are substituted by build-template.sh.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Start-Transcript -Path C:\Windows\Temp\template-prep.log -Append

function Wait-Network {
    Write-Host '==> Waiting for network/DNS'
    foreach ($i in 1..60) {
        try { [System.Net.Dns]::GetHostAddresses('packages.vmware.com') | Out-Null; return }
        catch { Start-Sleep -Seconds 5 }
    }
    throw 'No network/DNS after 5 minutes'
}
Wait-Network

# --- VMware Tools ------------------------------------------------------------
Write-Host '==> Installing VMware Tools'
$toolsBase = 'https://packages.vmware.com/tools/releases/latest/windows/x64/'
$idx = (Invoke-WebRequest -UseBasicParsing $toolsBase).Content
if ($idx -notmatch 'VMware-tools-[A-Za-z0-9.\-]+\.exe') { throw "No VMware Tools exe found at $toolsBase" }
$toolsExe = $Matches[0]
$toolsPath = "C:\Windows\Temp\$toolsExe"
Invoke-WebRequest -UseBasicParsing ($toolsBase + $toolsExe) -OutFile $toolsPath
Start-Process -FilePath $toolsPath -ArgumentList '/S', '/v', '/qn REBOOT=R' -Wait
Remove-Item $toolsPath -Force

# --- OpenSSH Server capability ----------------------------------------------
# Installed now (needs internet); deploys only enable + start the service.
Write-Host '==> Installing OpenSSH Server capability'
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }

# --- Cloudbase-Init ----------------------------------------------------------
Write-Host '==> Installing Cloudbase-Init'
$cbMsi = 'C:\Windows\Temp\CloudbaseInit.msi'
Invoke-WebRequest -UseBasicParsing 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile $cbMsi
Start-Process msiexec.exe -ArgumentList "/i `"$cbMsi`" /qn RUN_SERVICE_AS_LOCAL_SYSTEM=1" -Wait
Remove-Item $cbMsi -Force

$cbDir  = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
$common = @"
username=@DEFAULT_USERNAME@
groups=@ADMIN_GROUP@
inject_user_password=true
first_logon_behaviour=no
metadata_services=cloudbaseinit.metadata.services.vmwareguestinfoservice.VMwareGuestInfoService
allow_reboot=false
check_latest_version=false
bsdtar_path=$cbDir\bin\bsdtar.exe
mtools_path=$cbDir\bin\
logdir=$cbDir\log\
local_scripts_path=$cbDir\LocalScripts\
"@

Set-Content -Path "$cbDir\conf\cloudbase-init.conf" -Encoding ascii -Value @"
[DEFAULT]
$common
logfile=cloudbase-init.log
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.windows.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin,cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin
"@

Set-Content -Path "$cbDir\conf\cloudbase-init-unattend.conf" -Encoding ascii -Value @"
[DEFAULT]
$common
logfile=cloudbase-init-unattend.log
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin
"@

# --- Generalize + shut down --------------------------------------------------
# Remove the injected prep answers so clones never re-read them (sysprep will
# cache the Cloudbase Unattend.xml it is given instead).
Remove-Item -Path C:\Windows\Panther\unattend.xml -Force -ErrorAction SilentlyContinue
# Cloudbase's Unattend.xml re-invokes cloudbase-init during the clone's
# specialize pass. /generalize wipes machine identity AND the prep-only
# Administrator password/autologon set by autounattend.xml.
Write-Host '==> Running sysprep /generalize (VM will power off)'
Stop-Transcript
& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown `
    /unattend:"$cbDir\conf\Unattend.xml"
