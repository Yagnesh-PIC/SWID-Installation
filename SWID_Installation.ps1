Write-Output " "

# Pipeline Information
$organizationUrl = "https://tfsemea1.ta.philips.com/tfs/TPC_Region26"
$project = "MR"
$pat = "YOUR_PAT_HERE"  # Replace with your actual PAT

$headers = @{ 
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) 
}

#Credentials
$username = "gyrotest"
$password = ConvertTo-SecureString "kangoeroe" -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($username, $password)

# Get the site
$site = "bangalore"

# Get the hostname - Alter to integrate to dashboard
#$hostname = Read-Host "Enter hostname (e.g., MRBANWS219): "
$hostname = "MRBANWS219"
Write-Host "Running for host: $hostname" -ForegroundColor Cyan

Write-Output "Fetching current SWID"

#File Path
$netPath = "\\10.232.160.219\i$\reinstal\specific"
$driveLetter = "Z:"

New-PSDrive -Name $driveLetter.TrimEnd(':') -PSProvider FileSystem -Root $netPath -Credential $Credential -Persist
    
# Read file from mapped drive
$FilePath = "Z:\param_atsc.txt"
$fileContents = Get-Content -Path $FilePath

# Remove the mapped drive when done
Remove-PSDrive -Name $driveLetter.TrimEnd(':')

#Fetch current SWID
$swidPattern = "ARCHIVE_BUILD_FILE = (\d+)"
$streamPattern = "ARCHIVE_STREAM = (\S+)"
$matchedSwid = $fileContents | Select-String -Pattern $swidPattern
$matchedStream = $fileContents | Select-String -Pattern $streamPattern

if($matchedSwid -ne $null){
                            #Write-Output "Here"
    if($matchedSwid -match $swidPattern){
        $currentSwid = $matches[1]
        if($matchedStream -match $streamPattern){
            $currentStream = $matches[1]
            Write-Output " "
            Write-Host "Current SWID: $currentSwid (Stream: $currentStream)" -ForegroundColor Green
            Write-Output " "
    } else {
        Write-Output "Couldn't fetch current stream :("
    }
    } 
} else{
    Write-Output "Couldn't fetch current SWID :("
    exit
} 


# Prompt user for stream
$stream = Read-Host "Enter stream name (mrmain or mr1.0.0)"

switch ($stream.ToLower()) {
    "mrmain"   { $definitionId = "3015" }
    "mr1.0.0"  { $definitionId = "3744" }
    default    {
        Write-Output "Invalid stream name. Please enter 'mrmain' or 'mr1.0.0'."
        exit
    }
}

Write-Host "Selected stream: $stream" -ForegroundColor Magenta
#Write-Output "Using definitionId: $definitionId"

#Get ATSC IP Address
# $atscipPattern = "ATSC_IPADDRESS = (\d+)"
# $atscip = $fileContents | Select-String -Pattern $atscipPattern
$atscip = "130.141.172.24"

#Get System ID - Needs to be changed based on Hostname (DB Access required)
$systemId = "SYSTEM_ID_OF_HOST"


# Set how many latest builds to check
$topBuilds = 10

# Get latest N builds for the specific pipeline (build definition)
$uri = "$organizationUrl/$project/_apis/build/builds?definitions=$definitionId&`$top=$topBuilds&api-version=5.0"
$response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

if ($response.count -gt 0) {
    $builds = $response.value
    $foundSuccessfulBuild = $false

    foreach ($build in $builds) {
        $buildId = $build.id
        Write-Output "Checking Build ID: $buildId"

        # Check the job status and extract SWID number
        $timelineUri = "$organizationUrl/$project/_apis/build/builds/$buildId/timeline?api-version=5.0"
        $timeline = Invoke-RestMethod -Uri $timelineUri -Headers $headers -Method Get

        $jobNameToCheck = "SWIDConsolidation"
        $jobRecord = $timeline.records | Where-Object { $_.type -eq "Job" -and $_.name -eq $jobNameToCheck }

        if ($jobRecord -ne $null) {
            Write-Output "Job '$($jobRecord.name)' found with result: $($jobRecord.result)"

            if ($jobRecord.result -eq "succeeded") {
                Write-Output "Found latest successful SWIDConsolidation job in Build ID: $buildId"
                $foundSuccessfulBuild = $true

                # Fetch logs
                Write-Output "Fetching latest SWID for stream: $stream"
                $logUrl = "$organizationUrl/$project/_apis/build/builds/$buildId/logs/$($jobRecord.log.id)?api-version=5.0"
                $logContent = Invoke-RestMethod -Uri $logUrl -Headers $headers -Method Get

                # Define the pattern to match and capture the SWID number
                $pattern = "Subject: New $stream IBC SWID Available - (\d+)"

                # Search the log content for the matching line
                $matchedLine = $logContent | Select-String -Pattern $pattern

                if ($matchedLine -ne $null) {
                    if ($matchedLine -match $pattern) {
                        $swidNumber = $matches[1]
                        Write-Output " "
                        Write-Host "Latest SWID Number for stream: $stream is: $swidNumber" -ForegroundColor Green
                        Write-Output " "
                        if($currentSwid -ne $swidNumber){

                            #User Confirmation and Installation
                            $confirmation = Read-Host "Do you want to install SWID $swidNumber (Stream: $stream) (Y/N)"
                            if ($confirmation.ToUpper() -ne "Y") {
                                Write-Host "Installation cancelled by user." -ForegroundColor Red
                                exit
                            }
                            Write-Host "Proceeding with installation of SWID $swidNumber (Stream: $stream)"
                            #Write-Output "Works :)"
                            [Hashtable] $body = @{'perform'='YES'}
                            [string] $url = "http://$($atscip)/atsc_automation_interface/direct_installation.php?system_id=$($systemId)&installation_id=$($swidNumber)&Stream=$($stream)(Project)&installation_type=productcomposition"
                            $request = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/x-www-form-urlencoded' -Body $body -Verbose -Credential $Credential
                            if ($request.content -notmatch "CREATED INSTALL CONFIGURATION FILE FOR.*SUCCESFULL<BR>")
                            {
                                Write-Host "Something went wrong :(" -ForegroundColor Red
                                exit
                            }
                            Write-Output " "
                            Write-Host "Installation has started :)" -ForegroundColor Green
                        } else{
                            Write-Output "Latest Swid is same as current swid"
                        }      
                    }
                } else {
                    Write-Output "No matching line found in logs."
                }

                break # Stop after finding the latest successful build
            } else {
                Write-Output "Job '$($jobRecord.name)' did not succeed in Build ID: $buildId."
            }
        } else {
            Write-Output "Job '$jobNameToCheck' not found in Build ID: $buildId."
        }
    }

    if (-not $foundSuccessfulBuild) {
        Write-Output "No successful SWIDConsolidation job found in the latest $topBuilds builds."
    }
} else {
    Write-Output "No builds found for definition $definitionId."
    return
}
