using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Parse the body of the request
# ref https://docs.microsoft.com/en-us/azure/azure-resource-manager/managed-applications/publish-notifications#notification-schema
$eventType = $Request.Body.eventType
$applicationId = $Request.Body.applicationId
Write-Host $applicationId
$eventTime = $Request.Body.eventTime
$provisioningState = $Request.Body.provisioningState
$applicationDefinitionId = $Request.Body.applicationDefinitionId

Write-Host provisioning state: $provisioningState
# Return the repsonse to the caller if nothing else matches
$body = "This HTTP triggered function executed successfully. Please see the streaming logs for more information."

if ($provisioningState -match "Succeeded" ) {
    $body = "Hello, $name. This HTTP triggered function executed successfully."
    $a = $applicationId -split '/'
    $subscriptionId = $a[2]
    $resourceGroup = $a[4]
    $applicationName = $a[8]

    $resourceURI = "https://management.azure.com/"
    $tokenAuthURI = $env:MSI_ENDPOINT + "?resource=$resourceURI&api-version=2017-09-01"
    $tokenResponse = Invoke-RestMethod -Method Get -Headers @{"Secret" = "$env:MSI_SECRET" } -Uri $tokenAuthURI
    $accessToken = $tokenResponse.access_token
    
    Connect-AzAccount -AccessToken $accessToken -AccountId MSI@50342

    # accessing managed identity token
    # POST https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Solutions/applications/{applicationName}/listTokens?api-version=2018-09-01-preview HTTP/1.1
    # $listTokenUri = 'https://management.azure.com' + $applicationId + '/listTokens?api-version=2018-09-01-preview'
    # $body = @{
    #     "authorizationAudience"="https://management.azure.com/"
    # } |ConvertTo-Json
    # $mIdTokenResponse = Invoke-RestMethod -Uri $listTokenUri -ContentType "application/json" -Method POST -Body $body -Headers @{"Authorization" = "Bearer $accessToken" }
    # Write-Host $mIdTokenResponse
    # Write-Host $mIdTokenResponse.access_token

    # fetching managed app details
    $managedApp = Get-AzManagedApplication -ResourceGroupName $resourceGroup
    $mResourceGroupId = $managedApp.Properties.managedResourceGroupId
    $mResourceGroup = ($mResourceGroupId -split '/')[4]

    # getting details on the consumer data share account and storage account
    $dsAccount = Get-AzDataShareAccount -ResourceGroupName $mResourceGroup
    $dsStorageAccount = Get-AzStorageAccount -ResourceGroupName $mResourceGroup

    # This information comes from the provider's side
    $pResourceGroup="datashare0305rg"
    $pDSAccountName="datashare0305acct"
    $dsShare = Get-AzDataShare -ResourceGroupName $pResourceGroup -AccountName $pDSAccountName
    $dsDataSets = Get-AzDataShareDataSet -ResourceGroupName $pResourceGroup -AccountName $pDSAccountName -ShareName $dsShare.Name

    # get the managed identity of the managed application
    $managedAppResource = Get-AzResource -ResourceName $managedApp.Name
    $managedIdentity = $managedAppResource.Identity.PrincipalId
    $mtenantId = $managedAppResource.Identity.TenantId

    # generate an invite for the managed identity on the provider's side
    $invitation = New-AzDataShareInvitation -ResourceGroupName $pResourceGroup -AccountName $pDSAccountName -ShareName $dsShare.Name -Name $dsShare.Name -TargetObjectId $managedIdentity -TargetTenantId $mtenantId

    # accepting the invite 
    Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

    # need to do this using the managed identity
    New-AzDataShareSubscription -ResourceGroupName $mResourceGroup -AccountName $dsAccount.Name -Name $dsShare.Name -SourceShareLocation $dsAccount.Location -InvitationId $invitation.InvitationId

    # mapping datasets
    foreach ($dataset in $dsDataSets) {
        New-AzDataShareDataSetMapping -ResourceGroupName $mResourceGroup -AccountName $dsAccount.Name -StorageAccountResourceId $dsStorageAccount.Id -Container $dataset.ContainerName -Name $dsShare.Name -ShareSubscriptionName $dsShare.Name -DataSetId $dataset.Id
    }

    # start synchronization
    Start-AzDataShareSubscriptionSynchronization -ResourceGroupName $mResourceGroup -AccountName $dsAccount.Name -ShareSubscriptionName $dsShare.Name -SynchronizationMode FullSync
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $body
    })
