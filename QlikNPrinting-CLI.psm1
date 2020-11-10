#region Invoke-Connect-NPrinting_ps1
	<#
		.SYNOPSIS
			Creates a Authenticated Session Token
		
		.DESCRIPTION
			Connect-NPrinting creates the NPEnv Script Variable used to Authenticate Requests
			$Script:NPEnv
		
		.PARAMETER Prefix
			A description of the Prefix parameter.
		
		.PARAMETER Computer
			A description of the Computer parameter.
		
		.PARAMETER Port
			A description of the Port parameter.
		
		.PARAMETER Return
			A description of the Return parameter.
		
		.PARAMETER Credentials
			A description of the Credentials parameter.
		
		.PARAMETER TrustAllCerts
			A description of the TrustAllCerts parameter.
		
		.PARAMETER AuthScheme
			A description of the AuthScheme parameter.
		
		.NOTES
			Additional information about the function.
	#>
	function Connect-NPrinting
	{
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		param
		(
			[Parameter(ParameterSetName = 'Default')]
			[ValidateSet('http', 'https')]
			[string]$Prefix = 'https',
			[Parameter(ParameterSetName = 'Default',
					   Position = 0)]
			[string]$Computer = $($env:computername),
			[Parameter(ParameterSetName = 'Default',
					   Position = 1)]
			[string]$Port = '4993',
			[switch]$Return,
			[Parameter(ParameterSetName = 'Default')]
			[Parameter(ParameterSetName = 'Creds')]
			[pscredential]$Credentials,
			[Parameter(ParameterSetName = 'Default')]
			[switch]$TrustAllCerts,
			[ValidateSet('ntlm', 'NPrinting')]
			[string]$AuthScheme = "ntlm"
		)
		
		$APIPath = "api"
		$APIVersion = "v1"
		
		if ($PSVersionTable.PSVersion.Major -gt 5 -and $TrustAllCerts.IsPresent -eq $true)
		{
			$Script:SplatRest.Add("SkipCertificateCheck", $TrustAllCerts)
		}
		else
		{
			if ($TrustAllCerts.IsPresent -eq $true)
			{
				if (-not ("CTrustAllCerts" -as [type]))
				{
					add-type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class CTrustAllCerts {
    public static bool ReturnTrue(object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) { return true; }

    public static RemoteCertificateValidationCallback GetDelegate() {
        return new RemoteCertificateValidationCallback(CTrustAllCerts.ReturnTrue);
    }
}
"@
					Write-Verbose -Message "Added Cert Ignore Type"
				}
				
				[System.Net.ServicePointManager]::ServerCertificateValidationCallback = [CTrustAllCerts]::GetDelegate()
				[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
				Write-Verbose -Message "Server Certificate Validation Bypass"
			}
		}
		
		if ($Computer -eq $($env:computername))
		{
			$NPService = Get-Service -Name 'QlikNPrintingWebEngine'
			if ($null -eq $NPService)
			{
				Write-Error -Message "Local Computer Name used and Service in not running locally"
				break
			}
		}
		
		if ($Computer -match ":")
		{
			If ($Computer.ToLower().StartsWith("http"))
			{
				$Prefix, $Computer = $Computer -split "://"
			}
			
			if ($Computer -match ":")
			{
				$Computer, $Port = $Computer -split ":"
			}
		}
		$CookieMonster = New-Object System.Net.CookieContainer #[System.Net.CookieContainer]::new()
		$global:NPEnv = @{
			TrustAllCerts = $TrustAllCerts.IsPresent
			Prefix	      = $Prefix
			Computer	  = $Computer
			Port		  = $Port
			API		      = $APIPath
			APIVersion    = $APIVersion
			URLServerAPI  = ""
			URLServerNPE  = ""
			WebRequestSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession # [Microsoft.PowerShell.Commands.WebRequestSession]::new()
		}
		if ($null -ne $Credentials)
		{
			$NPEnv.Add("Credentials", $Credentials)
		}
		
		$NPEnv.URLServerAPI = "$($NPEnv.Prefix)://$($NPEnv.Computer):$($NPEnv.Port)/$($NPEnv.API)/$($NPEnv.APIVersion)"
		$NPEnv.URLServerNPE = "$($NPEnv.Prefix)://$($NPEnv.Computer):$($NPEnv.Port)"
		
		$WRS = $NPEnv.WebRequestSession
		$WRS.UserAgent = "Windows"
		$WRS.Cookies = $CookieMonster
		
		switch ($PsCmdlet.ParameterSetName)
		{
			'Default' {
				$WRS.UseDefaultCredentials = $true
				$APIAuthScheme = "ntlm"
				break
			}
			'Creds' {
				$WRS.Credentials = $Credentials
				$APIAuthScheme = "ntlm"
				break
			}
			'Certificate' {
				<#
				#Certificate Base Authentication does not currently work as the APIs cannot handle it.
				#Leaving this here in case this is added in the future.
				#Cert
				$NPrintCert = Get-ChildItem Cert:\LocalMachine\My\ | ?{ $_.Issuer -eq "CN=NPrinting-CA" }
				$UserCert = Get-ChildItem Cert:\CurrentUser\My -Eku "Client Authentication"
				$CertificateCollection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
				$CertificateCollection.Add($NPrintCert)
				$CertificateCollection.Add($UserCert)
				$WebRequestSession.Certificates = $CertificateCollection
				#>			
			}
		}
		
		if ($AuthScheme -eq "Nprinting")
		{
			$URLServerLogin = "$($NPEnv.URLServerNPE)"
		}
		else
		{
			$URLServerLogin = "$($NPEnv.URLServerAPI)/login/$($APIAuthScheme)"
		}
		
		Write-Verbose -Message $URLServerLogin
		$AuthToken = Invoke-NPRequest -path $URLServerLogin -method get
		$token = $NPenv.WebRequestSession.Cookies.GetCookies($URLServerLogin) | Where-Object{ $_.name -eq "NPWEBCONSOLE_XSRF-TOKEN" }
		$Header = New-Object 'System.Collections.Generic.Dictionary[String,String]'
		$Header.Add("X-XSRF-TOKEN", $token.Value)
		$NPEnv.header = $Header
		
		if ($AuthScheme -eq "NPrinting")
		{
			#With NPrinting Auth, we first have to get the X-XSRF-Token
			#then submit the credentials.
			$body = @{
				username = $Credentials.UserName
				password = $Credentials.GetNetworkCredential().Password
			} | ConvertTo-Json
			$URLServerLogin = "$($NPEnv.URLServerNPE)/login"
			$AuthToken = Invoke-NPRequest -path $URLServerLogin -method post -Data $body
			$body = $null
		}
		
		if ($Return -eq $true)
		{
			$AuthToken
		}
	}
	
	#Compatibility Alias Prior to renaming
	#Set-Alias -Name Get-NPSession -Value Connect-NPrinting
#endregion

#region Invoke-Invoke-NPRequest_ps1
	function Invoke-NPRequest
	{
		param
		(
			[Parameter(Mandatory = $true,
					   Position = 0)]
			[string]$Path,
			[ValidateSet('Get', 'Post', 'Patch', 'Delete', 'Put')]
			[string]$method = 'Get',
			$Data
		)
		if ($null -eq $NPEnv) { Connect-NPrinting }
		if ([uri]::IsWellFormedUriString($path, [System.UriKind]::Absolute))
		{
			$URI = $path
		}
		else
		{
			$URI = "$($NPEnv.URLServerAPI)/$($path)"
		}
		
		$Script:SplatRest = @{
			URI	       = $URI
			WebSession = $($NPEnv.WebRequestSession)
			Method	   = $method
			ContentType = "application/json"
			Headers    = $NPenv.header
		}
		
	
		if ("" -eq $NPEnv.WebRequestSession.Cookies.GetCookies($NPEnv.URLServerAPI) -and ($null -ne $NPEnv.Credentials))
		{
			$SplatRest.Add("Credential", $NPEnv.Credentials)
		}
		
		#Convert Data to Json and add to body of request
		if ($null -ne $data)
		{
			if ($Data.GetType().name -like "Array*")
			{
				$jsondata = Convertto-Json @($Data)
			}
			elseif ($Data.GetType().name -ne "string")
			{
				$jsondata = Convertto-Json $Data
			}
			else { $jsondata = $Data }
			
			#Catch All
			if (!(($jsondata.StartsWith('{') -and $jsondata.EndsWith('}')) -or ($jsondata.StartsWith('[') -and $jsondata.EndsWith(']'))))
			{
				$jsondata = $Data | Convertto-Json
			}
			
			$SplatRest.Add("Body", $jsondata)
		}
		
		if ($PSBoundParameters.Debug.IsPresent) { $Global:NPSplat = $SplatRest }
		
		try { $Result = Invoke-RestMethod @SplatRest  }
		catch [System.Net.WebException]{
			$EXCEPTION = $_.Exception
			Write-Warning -Message "From: $($Exception.Response.ResponseUri.AbsoluteUri) `nResponse: $($Exception.Response.StatusDescription)"
			return
		}
		
		if ($Null -ne $Result)
		{
			if ((($Result | Get-Member -MemberType Properties).count -eq 1 -and ($null -ne $Result.data)))
			{
				
				if ($null -ne $Result.data.items) { $Result.data.items }
				else { $Result.data }
				
			}
			else
			{
				$Result
			}
		}
		else { Write-Error -Message "no Results received" }
		
	}
#endregion

#region Invoke-GetNPFilter_ps1
	Function GetNPFilter ($Property, $Value, $Filter)
	{
		if ($null -ne $Property)
		{
			$Value = $Value.replace('*', '%')
			if ($Filter.StartsWith("?")) { $qt = "&" }
			else { $qt = "?" }
			$Filter = "$($Filter)$($qt)$($Property)=$($Value)"
		}
		$Filter
	}
#endregion

#region Invoke-Add-NPProperty_ps1
	
	Function Add-NPProperty ($Property,$NPObject,$path) {
	$PropertyValues = Get-Variable -Name "NP$($Property)" -ValueOnly -ErrorAction SilentlyContinue
	$NPObject | ForEach-Object{
	        $Object = $_
	        $ObjPath = "$($path)/$($Object.ID)/$Property"
	        $NPObjProperties = $(Invoke-NPRequest -Path $ObjPath -method Get)
	        $LookupProperties = $NPObjProperties | ForEach-Object{
	            $ObjProperty = $_;
	            $ObjectProperty = $PropertyValues | Where-Object{ $_.id -eq $ObjProperty }
	            if ($Null -eq $ObjectProperty)
	            {
	                Write-Verbose "$($ObjProperty) Missing from Internal $($Property) List: Updating"
	                & "Get-NP$($Property)" -update
	                $PropertyValues = Get-Variable -Name "NP$($Property)" -ValueOnly
	                $ObjectProperty = $PropertyValues | Where-Object{ $_.id -eq $ObjProperty }
	            }
	            $ObjectProperty
	        }
	        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Property -Value $LookupProperties
	    }
	}
	
#endregion

#region Invoke-Get-NPFilters_ps1
	function Get-NPFilters
	{
		param
		(
			[parameter(DontShow)]
			[switch]$Update
		)
		$Script:NPFilters = Invoke-NPRequest -Path "Filters" -method Get
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPFilters
		}
	}
#endregion

#region Invoke-Get-NPGroups_ps1
	Function Get-NPGroups
	{
		param
		(
			[int32]$limit,
			[parameter(DontShow)]
			[switch]$Update
		)
		$filter = ""
		if ("limit" -in $PSBoundParameters.Keys){ $Filter = GetNPFilter -Filter $Filter -Property "limit" -Value $limit.ToString() } 
		
		$Script:NPGroups = Invoke-NPRequest -Path "groups$Filter" -method Get
		
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPGroups
		}
	}
	
#endregion

#region Invoke-Get-NPRoles_ps1
	function Get-NPRoles
	{
		param
		(
			[parameter(DontShow)]
			[switch]$Update
		)
		
		$Script:NPRoles = Invoke-NPRequest -Path "roles" -method Get
		
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPRoles
		}
	}
#endregion

#region Invoke-Get-NPTasks_ps1
	function Get-NPTasks
	{
		param
		(
			$ID,
			[string]$Name,
			[switch]$Executions,
			[parameter(DontShow)]
			[switch]$Update
		)
		$BasePath = "tasks"
		
		if ($Null -ne $ID)
		{
			$Path = "$BasePath/$($ID)"
		}
		else
		{
			$Path = "$BasePath"
		}
		
		$Path = "$($Path)$($Filter)"
		Write-Verbose $Path
		
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		$Script:NPTasks = Invoke-NPRequest -Path $Path -method Get
		
		if ($Executions.IsPresent)
		{
			$NPTasks | ForEach-Object{
				$ExecutionPath = "tasks/$($_.id)/Executions"
				$NPTaskExecutions = Invoke-NPRequest -Path $ExecutionPath -method Get
				Add-Member -InputObject $_ -MemberType NoteProperty -Name "Executions" -Value $NPTaskExecutions
			}
		}
		
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPTasks
		}
		
	}
#endregion

#region Invoke-NPUsers_ps1
	
	<#
	#Avaliable APIs
	    Get-NPUsers
	    get /users
	    get /users/{id}
	    get /users/{id}/filters
	    get /users/{id}/groups
	    get /users/{id}/roles
	
	    Update-NPUser
	    put /users/{id}/filters
	    put /users/{id}/groups
	    put /users/{id}
	    put /users/{id}/roles
	
	    New-NPUser
	    post /users
	
	    Remove-NPUser
	    delete /users/{id}
	
	#>
	
	<#
	#Implemented APIS
	Get-NPUsers
	get /users
	get /users/{id}
	get /users/{id}/filters
	get /users/{id}/groups
	get /users/{id}/roles
	#>
	
	<#
		.SYNOPSIS
			Gets details of the Users in NPrinting
		
		.DESCRIPTION
			A detailed description of the Get-NPUsers function.
		
		.PARAMETER ID
			ID of object to get.
		
		.PARAMETER UserName
			Username of object to get.
		
		.PARAMETER Email
			Email address of object to get.
		
		.PARAMETER roles
			Include Role.
		
		.PARAMETER groups
			Inlcude Groups.
		
		.PARAMETER filters
			Include Filters.
		
		.PARAMETER limit
			number of objects to return (default is 50).
	
		.EXAMPLE
			Get-NPUsers -roles -groups -filters
			Get-NPUsers -UserName Marc -roles -groups -filters
		
		.NOTES
			Additional information about the function.
	#>
	function Get-NPUsers
	{
		[CmdletBinding()]
		param
		(
			[Parameter(ValueFromPipeline = $true)]
			[string]$ID,
			[string]$UserName,
			[string]$Email,
			[switch]$roles,
			[switch]$groups,
			[switch]$filters,
			[int32]$limit
		)
		$BasePath = "Users"
		$Filter = ""
		if ("limit" -in $PSBoundParameters.Keys) { $Filter = GetNPFilter -Filter $Filter -Property "limit" -Value $limit.ToString() }
		if ("UserName" -in $PSBoundParameters.Keys) { $Filter = GetNPFilter -Filter $Filter -Property "UserName" -Value $UserName }
		if ("EMail" -in $PSBoundParameters.Keys) { $Filter = GetNPFilter -Filter $Filter -Property "EMail" -Value $EMail }
		
		if ("ID" -in $PSBoundParameters.Keys) { $Path = "$BasePath/$($ID)" }
		else { $Path = "$BasePath" }
		
		$Path = "$($Path)$($Filter)"
		$NPUsers = Invoke-NPRequest -Path $Path -method Get
		
		if ($roles.IsPresent)
		{
			AddNPProperty -Property "Roles" -NPObject $NPUsers -path $BasePath
		}
		if ($groups.IsPresent)
		{
			AddNPProperty -Property "Groups" -NPObject $NPUsers -path $BasePath
		}
		if ($filters.IsPresent)
		{
			AddNPProperty -Property "Filters" -NPObject $NPUsers -path $BasePath
		}
		$NPUsers
	}
	
#endregion

#region Invoke-NPReports_ps1
	
	#This Function is a mess, it kinda works, but there will be filter scenarios where it is broken.
	#WIP
	function Get-NPReports{
		param
		(
			$ID,
			[string]$Name,
			[parameter(DontShow)]
			[switch]$Update
		)
		$BasePath = "Reports"
		
		if ($Null -ne $ID)
		{
			$Path = "$BasePath/$($ID)"
		}
		else
		{
			$Path = "$BasePath"
		}
		
		$Path = "$($Path)$($Filter)"
	    Write-Verbose $Path
	    
	    #The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		$Script:NPReports = Invoke-NPRequest -Path $Path -method Get
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPReports
		}
		
	}
	
#endregion

#region Invoke-NPApps_ps1
	
	#This Function is a mess, it kinda works, but there will be filter scenarios where it is broken.
	#WIP
	function Get-NPApps
	{
		param
		(
			$ID,
			[string]$Name,
			[parameter(DontShow)]
			[switch]$Update
		)
		$BasePath = "Apps"
		
		if ($Null -ne $ID)
		{
			$Path = "$BasePath/$($ID)"
		}
		else
		{
			$Path = "$BasePath"
		}
		
		$FilterApps = $Script:NPapps
		
		switch ($PSBoundParameters.Keys)
		{
			name{
				if ($Name -match '\*')
				{
					$FilterApps = $FilterApps | Where-Object { $_.name -like $Name }
				}
				else
				{
					$FilterApps = $FilterApps | Where-Object { $_.name -eq $Name }
				}
			}
			ID{ $Path = "$BasePath/$($ID)" }
			Update{ $Path = "$BasePath" }
			Default { $Path = "$BasePath" }
		}
		
		$Path = "$($Path)$($Filter)"
	    Write-Verbose $Path
	    
	    #The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		
		if ($Null -eq $FilterApps)
		{
			$Script:NPapps = Invoke-NPRequest -Path $Path -method Get
			if ($Update.IsPresent -eq $false)
			{
				$Script:NPapps
			}
		}
		else
		{
			if ($Update.IsPresent -eq $false)
			{
				$FilterApps
			}
			
		}
		
	}
	
#endregion

	<#	
		===========================================================================
		 Created with: 	SAPIEN Technologies, Inc., PowerShell Studio 2018 v5.5.155
		 Created on:   	2018-12-03 10:21 AM
		 Created by:   	Marc Collins
		 Organization: 	Qlik - Consulting
		 Filename:     	QlikNPrinting-CLI.psm1
		-------------------------------------------------------------------------
		 Module Name: QlikNPrinting-CLI
		===========================================================================
		Qlik NPrinting CLI - PowerShell Module to work with NPrinting
		The Function "Invoke-NPRequest" can be used to access all the NPrinting API's
	#>
	
# SIG # Begin signature block
# MIIeggYJKoZIhvcNAQcCoIIeczCCHm8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAFH7xf35PlyYTQ
# mFlD5BAXnW1Ih+P7Vrec5n30Dd0CcqCCGIwwggUwMIIEGKADAgECAhAECRgbX9W7
# ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMzEwMjIxMjAwMDBa
# Fw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/l
# qJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnkoOn7p0WfTxvspJ8fT
# eyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqH
# CN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q8grkV7tKtel05iv+
# bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLo
# LFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIB
# yTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBGMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAK
# BghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0j
# BBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcNAQELBQADggEBAD7s
# DVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGS
# dQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xGTlz/kLEbBw6RFfu6
# r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo
# +MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZHen6dGRrsutmQ9qz
# sIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdibqFT+hKUGIUukpHq
# aGxEMrJmoecYpJpkUe8wggYVMIIE/aADAgECAhAFRTa04g6mPPeCiV1MUKqsMA0G
# CSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0
# IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwHhcNMTkwNzIyMDAwMDAw
# WhcNMjIwNzEzMTIwMDAwWjBSMQswCQYDVQQGEwJBVTERMA8GA1UECBMIVmljdG9y
# aWExEjAQBgNVBAcTCU1lbGJvdXJuZTENMAsGA1UEChMETk5ldDENMAsGA1UEAxME
# Tk5ldDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANK1/Hj/BqB63rqE
# 3dowq0x7apSIKaKaC6QyjdTcElpJKbmcociClLRF36Svz6CSCd6OYfBFC6HCQjeW
# cBgC+dJ9bbEa4nOTBgS6U2p1QzJiBsjueZtctZiqZCf6K1N8ZzDVNU/mDzHU6Ekr
# d33cP8pMB/fafDAffkVu9ImT8UW7sYkH8m35S5cZ/dNHXEUCaa6SjNksmOjZOuHV
# 1aDbBnilw+6ebZkd6bZABalQlZiXnt5vSmUwkpxTMAEULy3pcLLKgumJ/Y+gj6ER
# 3NcdcaXs0AHNthNe9GhRPtskNbcNDqENcvDkyTwKmiplrStAKsziI/sSw4vdvtuq
# sDKBu1WVXtjoJdJF09AJ7dnv1cWXTdpoXU6b3KZKVE9e5j1JeN3FtgE5SgOulIAK
# MB4or+krtw4yL0qbrMHbvWn/Q3ZIIG+Bj4vHpJ2XghXXSjvskrRzjHKYgW3nGYaT
# th/HRI0HJbuOXgHLuKJ3qDsyRZElG7Amfq4mFEnIkJ2yLooImJqzT6zaD6DgDSEH
# BiEs53Wn2cNCTytmJxSIUkjUkmiP+QaaOI2hnlkmi6XbsEjt3ajVQYS5FM6Di8P9
# LQ2WuB6CiiXUXqyrimoG0xWQubx8iEUp0pGtS534nOrok2eKxPRm4IZQo5GWNsJg
# MsfjHq0iuJzxFu45DKP+fQAL9kPtAgMBAAGjggHFMIIBwTAfBgNVHSMEGDAWgBRa
# xLl7KgqjpepxA8Bg+S32ZXUOWDAdBgNVHQ4EFgQUFSv0DHHkjRjRJwaFIc02WgvW
# hFUwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHcGA1UdHwRw
# MG4wNaAzoDGGL2h0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9zaGEyLWFzc3VyZWQt
# Y3MtZzEuY3JsMDWgM6Axhi9odHRwOi8vY3JsNC5kaWdpY2VydC5jb20vc2hhMi1h
# c3N1cmVkLWNzLWcxLmNybDBMBgNVHSAERTBDMDcGCWCGSAGG/WwDATAqMCgGCCsG
# AQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5jb20vQ1BTMAgGBmeBDAEEATCB
# hAYIKwYBBQUHAQEEeDB2MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2Vy
# dC5jb20wTgYIKwYBBQUHMAKGQmh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFNIQTJBc3N1cmVkSURDb2RlU2lnbmluZ0NBLmNydDAMBgNVHRMBAf8E
# AjAAMA0GCSqGSIb3DQEBCwUAA4IBAQDdAL691XRUPt1IwCuENKw6n1sfTD7AAEzD
# 6zhprUrV6JWPFzJ4z/YgZp2LPYZDnh4m16/UI2O9pNMhykG3mg1ICJ45hTGZvRY+
# cM8aTV/ioG3lADJQ2Z9H624SKfLf+q/dT2Cq6Nv/9syj2PGx0POnuLHgz4c2VGVT
# bc3DdhSHRpikjisSl9JPUjpFjqlT/UTWfgLoMvv/D4p17EOZarT4ykAgE47zJbWJ
# S0cj3O1lnShDO7Xk+H/cv982frwWc2akrROov2deZ1uw/BcJ6AnCyX+gZkACtetd
# 0SmjQgOCUi/gVZUSIkWhSxJmj5wEV0IdJjKJLrafac5YtKXWlDuMMIIGajCCBVKg
# AwIBAgIQAwGaAjr/WLFr1tXq5hfwZjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQG
# EwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNl
# cnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBBc3N1cmVkIElEIENBLTEwHhcNMTQx
# MDIyMDAwMDAwWhcNMjQxMDIyMDAwMDAwWjBHMQswCQYDVQQGEwJVUzERMA8GA1UE
# ChMIRGlnaUNlcnQxJTAjBgNVBAMTHERpZ2lDZXJ0IFRpbWVzdGFtcCBSZXNwb25k
# ZXIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCjZF38fLPggjXg4PbG
# KuZJdTvMbuBTqZ8fZFnmfGt/a4ydVfiS457VWmNbAklQ2YPOb2bu3cuF6V+l+dSH
# dIhEOxnJ5fWRn8YUOawk6qhLLJGJzF4o9GS2ULf1ErNzlgpno75hn67z/RJ4dQ6m
# WxT9RSOOhkRVfRiGBYxVh3lIRvfKDo2n3k5f4qi2LVkCYYhhchhoubh87ubnNC8x
# d4EwH7s2AY3vJ+P3mvBMMWSN4+v6GYeofs/sjAw2W3rBerh4x8kGLkYQyI3oBGDb
# vHN0+k7Y/qpA8bLOcEaD6dpAoVk62RUJV5lWMJPzyWHM0AjMa+xiQpGsAsDvpPCJ
# EY93AgMBAAGjggM1MIIDMTAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0TAQH/BAIwADAW
# BgNVHSUBAf8EDDAKBggrBgEFBQcDCDCCAb8GA1UdIASCAbYwggGyMIIBoQYJYIZI
# AYb9bAcBMIIBkjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29t
# L0NQUzCCAWQGCCsGAQUFBwICMIIBVh6CAVIAQQBuAHkAIAB1AHMAZQAgAG8AZgAg
# AHQAaABpAHMAIABDAGUAcgB0AGkAZgBpAGMAYQB0AGUAIABjAG8AbgBzAHQAaQB0
# AHUAdABlAHMAIABhAGMAYwBlAHAAdABhAG4AYwBlACAAbwBmACAAdABoAGUAIABE
# AGkAZwBpAEMAZQByAHQAIABDAFAALwBDAFAAUwAgAGEAbgBkACAAdABoAGUAIABS
# AGUAbAB5AGkAbgBnACAAUABhAHIAdAB5ACAAQQBnAHIAZQBlAG0AZQBuAHQAIAB3
# AGgAaQBjAGgAIABsAGkAbQBpAHQAIABsAGkAYQBiAGkAbABpAHQAeQAgAGEAbgBk
# ACAAYQByAGUAIABpAG4AYwBvAHIAcABvAHIAYQB0AGUAZAAgAGgAZQByAGUAaQBu
# ACAAYgB5ACAAcgBlAGYAZQByAGUAbgBjAGUALjALBglghkgBhv1sAxUwHwYDVR0j
# BBgwFoAUFQASKxOYspkH7R7for5XDStnAs0wHQYDVR0OBBYEFGFaTSS2STKdSip5
# GoNL9B6Jwcp9MH0GA1UdHwR2MHQwOKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRENBLTEuY3JsMDigNqA0hjJodHRwOi8vY3Js
# NC5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURDQS0xLmNybDB3BggrBgEF
# BQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBB
# BggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# QXNzdXJlZElEQ0EtMS5jcnQwDQYJKoZIhvcNAQEFBQADggEBAJ0lfhszTbImgVyb
# hs4jIA+Ah+WI//+x1GosMe06FxlxF82pG7xaFjkAneNshORaQPveBgGMN/qbsZ0k
# fv4gpFetW7easGAm6mlXIV00Lx9xsIOUGQVrNZAQoHuXx/Y/5+IRQaa9YtnwJz04
# HShvOlIJ8OxwYtNiS7Dgc6aSwNOOMdgv420XEwbu5AO2FKvzj0OncZ0h3RTKFV2S
# Qdr5D4HRmXQNJsQOfxu19aDxxncGKBXp2JPlVRbwuwqrHNtcSCdmyKOLChzlldqu
# xC5ZoGHd2vNtomHpigtt7BIYvfdVVEADkitrwlHCCkivsNRu4PQUCjob4489yq9q
# jXvc2EQwggbNMIIFtaADAgECAhAG/fkDlgOt6gAK6z8nu7obMA0GCSqGSIb3DQEB
# BQUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNV
# BAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQg
# SUQgUm9vdCBDQTAeFw0wNjExMTAwMDAwMDBaFw0yMTExMTAwMDAwMDBaMGIxCzAJ
# BgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5k
# aWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMTCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOiCLZn5ysJClaWAc0Bw0p5W
# VFypxNJBBo/JM/xNRZFcgZ/tLJz4FlnfnrUkFcKYubR3SdyJxArar8tea+2tsHEx
# 6886QAxGTZPsi3o2CAOrDDT+GEmC/sfHMUiAfB6iD5IOUMnGh+s2P9gww/+m9/ui
# zW9zI/6sVgWQ8DIhFonGcIj5BZd9o8dD3QLoOz3tsUGj7T++25VIxO4es/K8DCuZ
# 0MZdEkKB4YNugnM/JksUkK5ZZgrEjb7SzgaurYRvSISbT0C58Uzyr5j79s5AXVz2
# qPEvr+yJIvJrGGWxwXOt1/HYzx4KdFxCuGh+t9V3CidWfA9ipD8yFGCV/QcEogkC
# AwEAAaOCA3owggN2MA4GA1UdDwEB/wQEAwIBhjA7BgNVHSUENDAyBggrBgEFBQcD
# AQYIKwYBBQUHAwIGCCsGAQUFBwMDBggrBgEFBQcDBAYIKwYBBQUHAwgwggHSBgNV
# HSAEggHJMIIBxTCCAbQGCmCGSAGG/WwAAQQwggGkMDoGCCsGAQUFBwIBFi5odHRw
# Oi8vd3d3LmRpZ2ljZXJ0LmNvbS9zc2wtY3BzLXJlcG9zaXRvcnkuaHRtMIIBZAYI
# KwYBBQUHAgIwggFWHoIBUgBBAG4AeQAgAHUAcwBlACAAbwBmACAAdABoAGkAcwAg
# AEMAZQByAHQAaQBmAGkAYwBhAHQAZQAgAGMAbwBuAHMAdABpAHQAdQB0AGUAcwAg
# AGEAYwBjAGUAcAB0AGEAbgBjAGUAIABvAGYAIAB0AGgAZQAgAEQAaQBnAGkAQwBl
# AHIAdAAgAEMAUAAvAEMAUABTACAAYQBuAGQAIAB0AGgAZQAgAFIAZQBsAHkAaQBu
# AGcAIABQAGEAcgB0AHkAIABBAGcAcgBlAGUAbQBlAG4AdAAgAHcAaABpAGMAaAAg
# AGwAaQBtAGkAdAAgAGwAaQBhAGIAaQBsAGkAdAB5ACAAYQBuAGQAIABhAHIAZQAg
# AGkAbgBjAG8AcgBwAG8AcgBhAHQAZQBkACAAaABlAHIAZQBpAG4AIABiAHkAIABy
# AGUAZgBlAHIAZQBuAGMAZQAuMAsGCWCGSAGG/WwDFTASBgNVHRMBAf8ECDAGAQH/
# AgEAMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MIGBBgNVHR8EejB4MDqgOKA2
# hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290
# Q0EuY3JsMDqgOKA2hjRodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRB
# c3N1cmVkSURSb290Q0EuY3JsMB0GA1UdDgQWBBQVABIrE5iymQftHt+ivlcNK2cC
# zTAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzANBgkqhkiG9w0BAQUF
# AAOCAQEARlA+ybcoJKc4HbZbKa9Sz1LpMUerVlx71Q0LQbPv7HUfdDjyslxhopyV
# w1Dkgrkj0bo6hnKtOHisdV0XFzRyR4WUVtHruzaEd8wkpfMEGVWp5+Pnq2LN+4st
# kMLA0rWUvV5PsQXSDj0aqRRbpoYxYqioM+SbOafE9c4deHaUJXPkKqvPnHZL7V/C
# SxbkS3BMAIke/MV5vEwSV/5f4R68Al2o/vsHOE8Nxl2RuQ9nRc3Wg+3nkg2NsWmM
# T/tZ4CMP0qquAHzunEIOz5HXJ7cW7g/DvXwKoO4sCFWFIrjrGBpN/CohrUkxg0eV
# d3HcsRtLSxwQnHcUwZ1PL1qVCCkQJjGCBUwwggVIAgEBMIGGMHIxCzAJBgNVBAYT
# AlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2Vy
# dC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNp
# Z25pbmcgQ0ECEAVFNrTiDqY894KJXUxQqqwwDQYJYIZIAWUDBAIBBQCggYQwGAYK
# KwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIB
# BDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg
# GcD7iH3o/goksBXd/VEvGES6lFlP2ju0gWdJtHWPC0AwDQYJKoZIhvcNAQEBBQAE
# ggIAOrKoR7EX/jjLnhsVj5iEopbKN10z+m7G6FfAtB65/B0cCvlzperKWIMs5epc
# 3M6sZ66ou8nbv0WjpogUE7FJN353hbfZ9I5aQMImp6OiQ4dENkVWDpECh0Cbdqap
# U4PGONVYdmVoUgIas5/dqe0HMhcuusm2g/1C6jbSttySecuqAz4rXlMgvV8N9krY
# gfl40nSzNKm2L8qIXhb9cocfokw/5zr7JgsRxxaZyDrvdgw303Xg+ddJjcjB/qb7
# IBmhJwh8fbBNiuDMsBd1aKFp8iBDL1o700Tkq2cj0oW83CEFzgH1w9qbX6hVV9Uz
# bcOONzi2yLAVdMjWiz+shVZdIq2Lyp47zv1WvQSUQhVQjRxFD9YoqFUcPH9rJVX3
# X+jQ5kt8QAAZOiaP9uLn0cwKRsqK2S8hAgw1DJZVrLk18hnTzVgAK8jA8sNXrZBq
# oIrUrvLBlPqtdHeQi0Mq4gh5M8rxGXjvR+CxjDczLMYTbQX55LR9hO7XxL/aW6oO
# tk13eFL1itc/3RZwS8b0LNQPrfgCRy8mu8BIulUaVJENXL/NHxZ8VnJ/O0NVcWeJ
# kgsgXZitvfk5Syy+62UvlESw9Q7BS84c/EQFyAVS8MwxDzExo2jmeDQEdbL8zkE5
# yox0h7f3gUAWDrqYEbJ1YgmqQYBHGJucUWHPq1mA9MZF7mKhggIPMIICCwYJKoZI
# hvcNAQkGMYIB/DCCAfgCAQEwdjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGln
# aUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhE
# aWdpQ2VydCBBc3N1cmVkIElEIENBLTECEAMBmgI6/1ixa9bV6uYX8GYwCQYFKw4D
# AhoFAKBdMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8X
# DTIwMTExMDAyMzEyNlowIwYJKoZIhvcNAQkEMRYEFMddc2EeytTB9pTd6eqSjyVU
# h6+QMA0GCSqGSIb3DQEBAQUABIIBAIxRKKTBBQwq8AY1fVKnX4XjknPqyeIWq09r
# G7kjqxgp9u544mbJ2Ku4exaW7MIZAjQZ26fJJDh1Y+g8+D/fl98gKgkKRcIb9McA
# kZ7S1BNT49bAcOY3y/NdbamZD5J5dAOSEX+7UmovXDtd+QKjpTlWg4c9u+YBupQs
# 0FaKpXKg5v6kG5IVlGuHSmHiVZselp8q4WTRYxTlbgUqxajO8tBGi7OdQbE27S2p
# TKwWkDg1ebqBIKQW8QRclL3XVuUQ43eCTqijvji8tgj5x0dKeuel2m6ZZ8fmsPqY
# RLjSE4iKG88RP/3s3p6G9UKQCmMjsDRw4xQSRTeFn+2HV5dTKbs=
# SIG # End signature block
