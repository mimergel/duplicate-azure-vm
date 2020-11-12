<#
.SYNOPSIS
    Copy a VM into another VNET/subnet and new Resource Group.
.DESCRIPTION
	The target Resource Group will be created if does not yet exist.
	The VNET/subnet must exist.
    IMPORTANT: The script does not move VM extensions or any identities assigned to the Virtual Machine.  
	Also, the script will not work for VMs with public IP addresses. Remove these upfront manually.
.EXAMPLE
	./duplicate-vm-into-another-subnet.ps1 -SubscriptionName "Azure Subscription Name" `
	-ResourceGroupName SAP01 `
	-NewResourceGroupName SAP02 `
	-VirtualMachineName sapdemo01 `
	-NewVirtualMachineName sapdemo02 `
	-TargetVNETName  SAPNetwork `
	-TargetSubnetName  sapdevsubnet 	

.LINKs
    https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities
	https://github.com/mimergel/duplicate-azure-vm

.NOTES
    v0.1 - Initial version
#>

#Requires -Modules Az.Compute
#Requires -Modules Az.Network
#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$SubscriptionName,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName, 
    [Parameter(Mandatory = $true)][string]$NewResourceGroupName,
    [Parameter(Mandatory = $true)][string]$VirtualMachineName,
    [Parameter(Mandatory = $true)][string]$NewVirtualMachineName,
    [Parameter(Mandatory = $true)][string]$TargetVNETName,
    [Parameter(Mandatory = $true)][string]$TargetSubnetName
)

# select subscription
Write-Verbose "setting azure subscription"
$Subscription = Get-AzSubscription -SubscriptionName $SubscriptionName
if (-Not $Subscription) {
    Write-Host -ForegroundColor Red -BackgroundColor White "Sorry, it seems you are not connected to Azure or don't have access to the subscription. Please use Connect-AzAccount to connect."
    exit
}
Select-AzSubscription -Subscription $SubscriptionName -Force

# Get the details of the source VM 
Write-Verbose  ""
Write-Verbose  "getting VM config"
$originalVM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName

# Create Resource Group if not existing
Write-Verbose "checking target resource group"
$NewRG = Get-AzResourceGroup -ResourceGroupName $NewResourceGroupName
if (-Not $NewRG) {
    Write-Host -ForegroundColor Red -BackgroundColor White "Creating missing New VM Target Resource Group"
	New-AZResourceGroup -Name $NewResourceGroupName -Location $originalVM.location
}

# We don't support moving machines with public IPs, since those are zone specific.  check for that here.
foreach ($nic in $originalVM.NetworkProfile.NetworkInterfaces) {
    $thenic = $nic.id
    $nicname = $thenic.substring($thenic.LastIndexOf("/") + 1)
    $othernic = Get-AzNetworkInterface -Name $nicname -ResourceGroupName $ResourceGroupName 
    foreach ($ipc in $othernic.IpConfigurations) {
        $pip = $ipc.PublicIpAddress
        if ($pip) { 
            Write-Host -ForegroundColor Red "Sorry, machines with public IPs are not supported by this script" 
            exit
        }
    }
}

[string]$osType = $originalVM.StorageProfile.OsDisk.OsType
[string]$location = $originalVM.Location
[string]$storageType = $originalVM.StorageProfile.OsDisk.ManagedDisk.StorageAccountType

$tags = $originalVM.Tags
    
#  Create the basic configuration for the replacement VM
$newVM = New-AzVMConfig -VMName $NewVirtualMachineName -VMSize $originalVM.HardwareProfile.VmSize -Tags $tags
       
Write-Verbose  "copy os disk"
$osdiskname = $originalVM.StorageProfile.OsDisk.Name
$NewOSDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $osdiskname
$NewOSDiskName = $NewVirtualMachineName + "-os"
$NewOSDiskConfig = New-AzDiskConfig -SourceResourceId $NewOSDisk.Id -Location $NewOSDisk.Location -CreateOption Copy
$newdisk = New-AzDisk -Disk $NewOSDiskConfig -DiskName $NewOSDiskName -ResourceGroupName $NewResourceGroupName

Write-Verbose  ("new disk info {0}" -f $newdisk.ManagedDisk.Id)
Write-Verbose  ("newdisk {0}" -f $newdisk )
Write-Verbose  ("newdisk.manageddisk {0}" -f $newdisk.ManagedDisk)
Write-Verbose  ("newdisk.manageddisk.id {0}" -f $newdisk.ManagedDisk.Id)
Write-Verbose  ("the newdisk value is {0}" -f $newdisk)
Write-Verbose  ("the newdisk.Id value is {0}" -f $newdisk.Id)
if ($osType -eq "Linux") {
    Write-Verbose "OS Type is Linux"
    Set-AzVMOSDisk -VM $newVM -CreateOption Attach  -ManagedDiskId $newdisk.Id -Name $newdisk.Name  -Linux
}
if ($osType -eq "Windows") {
    Write-Verbose "OS Type is Windows"
    Set-AzVMOSDisk -VM $newVM -CreateOption Attach  -ManagedDiskId $newdisk.Id -Name $newdisk.Name  -Windows		
}

# copy all of the drives
$counter = 0
foreach ($disk in $originalVM.StorageProfile.DataDisks) {
 	$counter++
	$newdisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $disk.Name
	$newdiskname = $NewVirtualMachineName  + "-disk-" + $counter
	$newdiskconfig = New-AzDiskConfig -SourceResourceId $newdisk.Id -Location $newdisk.Location -CreateOption Copy
	$newdatadisk = New-AzDisk -Disk $newdiskconfig -DiskName $newdiskname -ResourceGroupName $NewResourceGroupName
	# Attach to VM
    Add-AzVMDataDisk -VM $newVM -Name $newdatadisk.Name -ManagedDiskId $newdatadisk.Id `
	       -Caching $disk.Caching `
	       -Lun $disk.Lun `
		   -DiskSizeInGB $newdatadisk.DiskSizeGB `
	       -CreateOption Attach
}

# Get information about target subnet
$NewVirtualNetwork = Get-AzVirtualNetwork -Name $TargetVNETName 
$NewSubnet = Get-AzVirtualNetworkSubnetConfig -Name $TargetSubnetName -VirtualNetwork $NewVirtualNetwork

# Create new NIC and attach to VM config
$counter = 0
foreach ($nic in $originalVM.NetworkProfile.NetworkInterfaces) {
    if ($nic.Primary -eq "True") {
		$newnicname = $NewVirtualMachineName + "-primary-nic"
        $NewNIC = New-AzNetworkInterface -Name $newnicname -ResourceGroupName $NewResourceGroupName `
			-Location $NewVirtualNetwork.location -SubnetId $NewSubnet.id
		Add-AzVMNetworkInterface -VM $newVM -Id $NewNIC.Id -Primary
    }
    else {
		$counter++
		$newnicname = $NewVirtualMachineName + "-nic" + $counter
        $NewNIC = New-AzNetworkInterface -Name $newnicname -ResourceGroupName $NewResourceGroupName `
			-Location $NewVirtualNetwork.location -SubnetId $NewSubnet.id
		Add-AzVMNetworkInterface -VM $newVM -Id $NewNIC.Id
    }
}
Write-Verbose  "creating new VM"
New-AzVM -ResourceGroupName $NewResourceGroupName -Location $originalVM.Location -VM $newVM -DisableBginfoExtension 

