<#
      .SYNOPSIS
      Runbook which queries VMs in a Recovery Services Plan and updates their DNS A records

      .DESCRIPTION
      This runbook is designed for use with an Azure runbook.

      It will pull the VMs from a recovery services plan then determine whether or not those VMs are currently in Production or DR,
      based on that it works out what the new IP addresses should be and pushes the changes out to your DNS server remotely.

      .PARAMETER RecoveryServicesVault
      Mandatory
      Name of your Recovery Services Vault

      .PARAMETER RecoveryServicesPlan
      Mandatory
      Name of your Recovery Services Plan

      .PARAMETER DNSServer
      Mandatory
      Name of your Active Directory DNS server

      .PARAMETER DNSZoneName
      Mandatory
      Name of your Active Directory DNS zone

      .PARAMETER PRDNetwork
      Mandatory
      Network address of your Production network

      .PARAMETER DRNetwork
      Mandatory
      Network address of your DR network

      .EXAMPLE
        
      .OUTPUTS

      .NOTES
      Written by Tyson Johnson
#>

Param(
      [Parameter(Mandatory = $true)]
      [string]$RecoveryServicesVault,

      [Parameter(Mandatory = $true)]
      [string]$RecoveryServicesPlan,

      [Parameter(Mandatory = $true)]
      [string]$DNSServer,

      [Parameter(Mandatory = $true)]
      [string]$DNSZoneName,

      [Parameter(Mandatory = $true)]
      [string]$PRDNetwork,

      [Parameter(Mandatory = $true)]
      [string]$DRNetwork
   )

# DNS script used to update DNS server
$scriptHere = @"
Param(
      [Parameter(Mandatory = `$true)]
      [string]`$DNSList
   )

`$dnsListObj = `$DNSList | ConvertFrom-Json

foreach (`$record in `$dnsListObj)
{
    try
    {
        # Remove old record
        Remove-DnsServerResourceRecord ``
            -ZoneName `$record.Zone ``
            -RRType "A" ``
            -Name `$record.Hostname ``
            -Confirm:`$false ``
            -Force

        # Add new record
        Add-DnsServerResourceRecordA ``
            -Name `$record.Hostname ``
            -ZoneName `$record.Zone ``
            -AllowUpdateAny ``
            -IPv4Address `$record.IP ``
            -Confirm:`$false
    }
    catch
    {
        throw `$error
    }
}
"@

# Authenticate to Azure
try
{
   $runAs = Get-AutomationConnection -Name 'AzureRunAsConnection'

   Connect-AzAccount `
      -ServicePrincipal `
      -Tenant $runAs.TenantID `
      -ApplicationId $runAs.ApplicationID `
      -CertificateThumbprint $runAs.CertificateThumbprint
}
catch
{
   Write-Error -Message "Failed to authenticate"
   throw $_.Exception
}

try
{
   # Get recovery services vault and set context
   $vault = Get-AzRecoveryServicesVault -Name $RecoveryServicesVault
   Set-AzRecoveryServicesAsrVaultContext -Vault $vault

   # Get ASR plan and pull all involved VMs
   $plan = Get-AzRecoveryServicesAsrRecoveryPlan -Name $RecoveryServicesPlan
   $vmList = $plan.groups.ReplicationProtectedItems.RecoveryAzureVMName
}
catch
{
   Write-Error -Message "Failed to pull ASR details"
   throw $_.Exception
}

try
{
   # Determine if currently in Prod or DR
   $activeVM = Get-AzVM -Name $vmList[0] -Status | where PowerState -eq 'VM running'
   $nicId = ($activeVM.NetworkProfile.NetworkInterfaces.id -split '/')[-1]
   $nicDetails = (Get-AzNetworkInterface -Name $nicId)
   $activeNic = ($nicDetails | where ResourceGroupName -eq $activeVM.ResourceGroupName)
   $ipCheck = $activeNic.IpConfigurations.PrivateIpAddress
}
catch
{
   Write-Error -Message "Failed to determine if currently in PRD or DR"
   throw $_.Exception
}

try
{
   # Get netmask convert to CIDR, check if IP is in range for DR or PROD
   # Convert netmask bits to cidr then determine range of the network
   $maskBits = ((Get-AzVirtualNetworkSubnetConfig -ResourceId $activeNic.IpConfigurations.Subnet.Id).AddressPrefix).Split('/')[-1]
   [IPAddress]$maskObj = 0 # Initiate ipaddress object
   $maskObj.Address = ([UInt32]::MaxValue) -shl (32 - $maskBits) -shr (32 - $maskBits) # Convert bits to cidr format
   [string]$maskCidr = $maskObj.ToString()
   $ipBits = [int[]]$ipCheck.Split('.')
   $maskBits = [int[]]$maskCidr.Split('.')
   $networkIDBits = 0..3 | foreach { $ipBits[$_] -band $maskBits[$_] } # Calculate the Nerwork ID using the current IP address and cidr netmask
   $networkID = $networkIDBits -join '.'

   # If matches PRD fail to DR
   if ($PRDNetwork -eq $networkID)
   {
      $failTo = 'DR'
   }
   else
   {
      $failTo = 'PRD'
   }

   # Determine which octets are changing
   $prdNet = $PRDNetwork.split('.')
   $drNet = $DRNetwork.split('.')
   for ($i = 0; $i -le 2; $i++)
   {
      if ($prdNet[$i] -ne $drNet[$i])
      {
         [array]$changedOctet += $i
      }
   }
}
catch
{
   Write-Error -Message "Failed to calculate network"
   throw $_.Exception
}

# Itterate through VMs and update DNS records accordingly
foreach ($vm in $vmList)
{
   # Get the name of the NIC then lookup its ip address
   $activeVM = Get-AzVM -Name $vm -Status | where PowerState -eq 'VM running'
   $nicId = ($activeVM.NetworkProfile.NetworkInterfaces.id -split '/')[-1]
   $nicConfig = (Get-AzNetworkInterface -Name $nicId)
   $activeVmNic = ($nicConfig | where ResourceGroupName -eq $activeVM.ResourceGroupName)
   $ipAddress = $activeVmNic.IpConfigurations.PrivateIpAddress

   if ($failTo -eq 'PRD')
   {
      # Modify the IP
      $octets = $ipAddress.Split('.')
      foreach ($octet in $changedOctet)
      {
         $octets[$octet] = [string]([int]$octets[$octet] = $prdNet[$octet])
      }
      $newIpAddress = $octets -join "."

      # Build object containing data to pass to Update-DNSRecords
      [array]$dnsSettings += New-Object PSObject -Property @{
         Hostname =  $vm
         IP       =  $newIpAddress
         Zone     =  $DNSZoneName
      }
   }
   elseif ($failTo -eq 'DR')
   {
      # Modify the IP
      $octets = $ipAddress.Split('.')
      foreach ($octet in $changedOctet)
      {
         $octets[$octet] = [string]([int]$octets[$octet] = $drNet[$octet])
      }
      $newIpAddress = $octets -join "."

      # Build object containing data to pass to Update-DNSRecords
      [array]$dnsSettings += New-Object PSObject -Property @{
         Hostname =  $vm
         IP       =  $newIpAddress
         Zone     =  $DNSZoneName
      }
   }
   else 
   {
      Write-Error -Message "Failed to configure new IPs"
      throw $_.Exception
   }
}

try
{
   $scriptName = "Update-DNSRecords.ps1"
   $stagePath = "$env:TEMP\$scriptName"
   Out-File -FilePath $stagePath -InputObject $scriptHere -NoNewline -Force
}
catch 
{
   Write-Error -Message "Failed to export DNS script"
   throw $_.Exception
}

try
{
   # run script on DNS server, convert parameters to JSON string (Invoke-AzVMRunCommand has serious parameter limitations, this is a workaround)
   [string]$dnsSettingsJson = $dnsSettings | ConvertTo-Json -Compress

   Invoke-AzVMRunCommand `
      -ResourceGroupName $((Get-AzVM -Name $DNSServer).ResourceGroupName) `
      -Name $DNSServer `
      -CommandId 'RunPowerShellScript' `
      -ScriptPath $stagePath `
      -Parameter @{
         DNSList  =  $dnsSettingsJson
      }
}
catch
{
   Write-Error -Message "Failed to run script on remote VM"
   throw $_.Exception
}