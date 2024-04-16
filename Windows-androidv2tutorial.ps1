param( 
    [string]$appName, 
    [string]$packageName, 
    [string]$signatureHash
    ) 

# check if signing key is provided 
if (-not $signatureHash) { 
    # Run the signingReport task 
    $gradleOutput = ./gradlew signingReport 
    # Extract the SHA-1 key 
    
    $sha1Regex = "(?<=SHA1:\s)([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){19})" 

    $sha1Hashes = [regex]::Matches($gradleOutput, $sha1Regex) 
    
    if ($sha1Hashes.Count -gt 0) { 
        $sha1Key = $sha1Hashes[0].Value 
        $sanitizedSha1 = $sha1Key -replace '\W' 
        $bytes = [byte[]] -split ($sanitizedSha1 -replace '..', '0x$& ') 
        $base64Sha1 = [System.Convert]::ToBase64String($bytes) 
        } else { 
            Write-Host "Error: Unable to find SHA-1 key in the signing report." 
        }
        Write-Host "Base64 SHA-1: $base64Sha1" 
        $signatureHash = $base64Sha1 
    }
# Check if Azure CLI is installed
function Test-AzCLIInstalled {
    try {
        az --version | Out-Null
        return $true
    } catch {
        return $false
    }
}
# install CLI if not installed
if (-not (Test-AzCLIInstalled)) {
    Write-Host "Azure CLI not found. Attempting to download and install..."

    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
        Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
        Remove-Item .\AzureCLI.msi

        if (-not (Test-AzCLIInstalled)) {
            throw "Azure CLI installation failed."
        }
    } catch {
        Write-Host "Error downloading or installing Azure CLI: $_" -ForegroundColor Red
        exit
    }
} else {
    Write-Host "Azure CLI is already installed."
}


# Generates a redirect URI 

$redirectUri = "msauth://$packageName/$signatureHash" 

# Login to Azure 

Write-Host "Please Log in to Azure..." 

az login --tenant TENANT_ID

# Create the app registration 

$appRegistration = az ad app create --display-name $appName 

# Extract the App (Client) ID 

$appId = $appRegistration.appId

# add redirect URI to the app registration 

$app = az ad app list --display-name $appName --query "[].{id:appId}" --output tsv 

$appId = $app.Trim()

az ad app update --id $appId --public-client-redirect-uris $redirectUri 

Write-Host "App registration updated with redirect URI"
    
# Generate MSAL Config file 

$configJson = @{
    "client_id" = "$appId"
    "authorization_user_agent" = "WEBVIEW"
    "redirect_uri" = "$redirectUri"
    "account_mode" = "MULTIPLE"
    "broker_redirect_uri_registered" = $true
    "authorities" = @(
        @{
            "type" = "AAD"
            "authority_url" = "https://login.microsoftonline.com/common"
            "default" = $true
        }
    )
} | ConvertTo-Json -Depth 10
# check if folder .\app\src\main\res\raw exists otherwise create it 

if (-not (Test-Path -Path "app/src/main/res/raw")) { 
    
    New-Item -Path "./app/src/main/res/raw" -ItemType File 
    }
$configFilePath = "./app/src/main/res/raw/auth_config_multiple_account.json"
Write-Host "MSAL config file generated at $configFilePath"

# Generate MSAL Helper file 

$msalHelper = @"
package $packageName

import android.app.Activity
import android.content.Context
import com.microsoft.identity.client.AcquireTokenParameters
import com.microsoft.identity.client.AuthenticationCallback
import com.microsoft.identity.client.IMultipleAccountPublicClientApplication
import com.microsoft.identity.client.IPublicClientApplication
import com.microsoft.identity.client.Prompt
import com.microsoft.identity.client.PublicClientApplication
import com.microsoft.identity.client.exception.MsalException 

object MsalHelper { 
    private var sApplication: IPublicClientApplication? = null 
    private fun createApplication(context: Context) { 
        PublicClientApplication.createMultipleAccountPublicClientApplication(context,
        R.raw.auth_config_multiple_account, 
        object : IPublicClientApplication.IMultipleAccountApplicationCreatedListener {
            override fun onCreated(application: IMultipleAccountPublicClientApplication) {
                sApplication = application;
            } 
            override fun onError(exception: MsalException) {}
        }) 
    }

    fun acquireToken(activity: Activity, callback: AuthenticationCallback) {
        if (sApplication == null) { 
            createApplication(activity)
        }
        val parameters: AcquireTokenParameters = AcquireTokenParameters.Builder()
            .startAuthorizationFromActivity(activity)
            .fromAuthority("https://login.microsoftonline.com/08af321a-c895-4f78-afbd-6cede994e80f")
            .withPrompt(Prompt.SELECT_ACCOUNT)
            .withScopes(listOf("user.read"))
            .withCallback(callback)
            .build()

        sApplication?.acquireToken(parameters)
    }
}
"@

$msalhelperPath = ".\app\src\main\java\" + $packageName.replace(".", "\") + "\MsalHelper.kt" 
$msalHelper | Out-File -FilePath $msalhelperPath -Encoding utf8 

Write-Host "MSAL helper file generated at $msalhelperPath" 
 
