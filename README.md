# Set-ASRFailoverDNS
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
