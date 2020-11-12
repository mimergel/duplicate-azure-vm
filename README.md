Copy a VM into another VNET/subnet and new Resource Group.

The target Resource Group will be created if does not yet exist.
The target subnet must exist.

The script does not move VM extensions or any identities assigned to the Virtual Machine.
Also, the script will not work for VMs with public IP addresses. Remove these upfront manually.

Example:


```ps1

./duplicate-vm-into-another-subnet.ps1 -SubscriptionName "Azure Subscription Name" `
-ResourceGroupName OldRg  `
-NewResourceGroupName NewRg  `
-VirtualMachineName oldvmname  `
-NewVirtualMachineName newvmname  `
-TargetVNETName vnetname  `
-TargetSubnetName subnetname 

```
