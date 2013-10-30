$psake.use_exit_on_error = $true
properties {
    $baseDir = (Split-Path -parent $psake.build_script_dir)
    if(Get-Command Git -ErrorAction SilentlyContinue) {
        $versionTag = git describe --abbrev=0 --tags
        $version = $versionTag + "."
        $version += (git log $($version + '..') --pretty=oneline | measure-object).Count
        $changeset=(git log -1 $($versionTag + '..') --pretty=format:%H)
    }
    else {
        $version="1.0.0"
    }
    $nugetExe = "$env:ChocolateyInstall\ChocolateyInstall\nuget"
    $ftpHost="waws-prod-bay-001.ftp.azurewebsites.windows.net"
}

Task default -depends Build
Task Build -depends Build-Clickonce, Test, Package
Task Deploy -depends Build, Deploy-DownloadZip, Publish-Clickonce, Update-Homepage -description 'Versions, packages and pushes to Myget'
Task Package -depends Clean-Artifacts, Version-Module, Pack-Nuget, Create-ModuleZipForRemoting, Package-DownloadZip -description 'Versions the psd1 and packs the module and example package'
Task Push-Public -depends Push-Codeplex, Push-Chocolatey
Task All-Tests -depends Test, Integration-Test

task Create-ModuleZipForRemoting {
    if (Test-Path "$basedir\Boxstarter.Chocolatey\Boxstarter.zip") {
      Remove-Item "$baseDir\Boxstarter.Chocolatey\boxstarter.zip" -Recurse -Force
    }
    if(!(Test-Path "$baseDir\buildArtifacts")){
        mkdir "$baseDir\buildArtifacts"
    }
    Remove-Item "$env:temp\Boxstarter.zip" -Force -ErrorAction SilentlyContinue
    ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\buildartifacts\Boxstarter.zip" "$basedir\boxstarter.Common" | out-Null
    ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\buildartifacts\Boxstarter.zip" "$basedir\boxstarter.WinConfig" | out-Null
    ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\buildartifacts\Boxstarter.zip" "$basedir\boxstarter.bootstrapper" | out-Null
    ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\buildartifacts\Boxstarter.zip" "$basedir\boxstarter.chocolatey" | out-Null
    ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\buildartifacts\Boxstarter.zip" "$basedir\boxstarter.config" | out-Null
    ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\buildartifacts\Boxstarter.zip" "$basedir\license.txt" | out-Null
    Move-Item "$basedir\buildartifacts\Boxstarter.zip" "$basedir\boxstarter.chocolatey\Boxstarter.zip"
}

task Build-ClickOnce {
    Update-AssemblyInfoFiles $version $changeset
    exec { msbuild "$baseDir\Boxstarter.ClickOnce\Boxstarter.WebLaunch.csproj" /t:Clean /v:quiet }
    exec { msbuild "$baseDir\Boxstarter.ClickOnce\Boxstarter.WebLaunch.csproj" /t:Build /v:quiet }
}

task Publish-ClickOnce {
    exec { msbuild "$baseDir\Boxstarter.ClickOnce\Boxstarter.WebLaunch.csproj" /t:Publish /v:quiet /p:ApplicationVersion="$version.0" }
    Remove-Item "$basedir\public\Launch" -Recurse -Force -ErrorAction SilentlyContinue
    MkDir "$basedir\public\Launch"
    Set-Content "$basedir\public\Launch\.gitattributes" -Value "* -text"
    Copy-Item "$basedir\Boxstarter.Clickonce\bin\Debug\App.Publish\*" "$basedir\public\Launch" -Recurse -Force
}

Task Test -depends Create-ModuleZipForRemoting {
    pushd "$baseDir"
    $pesterDir = (dir $env:ChocolateyInstall\lib\Pester*)
    if($pesterDir.length -gt 0) {$pesterDir = $pesterDir[-1]}
    if($testName){
        exec {."$pesterDir\tools\bin\Pester.bat" $baseDir/Tests -testName $testName}
    }
    else{
        exec {."$pesterDir\tools\bin\Pester.bat" $baseDir/Tests }
    }
    popd
}

Task Integration-Test -depends Pack-Nuget {
    pushd "$baseDir"
    $pesterDir = (dir $env:ChocolateyInstall\lib\Pester*)
    if($pesterDir.length -gt 0) {$pesterDir = $pesterDir[-1]}
    if($testName){
        exec {."$pesterDir\tools\bin\Pester.bat" $baseDir/IntegrationTests -testName $testName}
    }
    else{
        exec {."$pesterDir\tools\bin\Pester.bat" $baseDir/IntegrationTests }
    }
    popd
}

Task Version-Module -description 'Stamps the psd1 with the version and last changeset SHA' {
    Get-ChildItem "$baseDir\**\*.psd1" | % {
       $path = $_
        (Get-Content $path) |
            % {$_ -replace "^ModuleVersion = '.*'`$", "ModuleVersion = '$version'" } | 
                % {$_ -replace "^PrivateData = '.*'`$", "PrivateData = '$changeset'" } | 
                    Set-Content $path
    }
    (Get-Content "$baseDir\BuildScripts\bootstrapper.ps1") |
        % {$_ -replace " -version .*`$", " -version $version" } | 
            Set-Content "$baseDir\BuildScripts\bootstrapper.ps1"
}

Task Clean-Artifacts {
    if (Test-Path "$baseDir\buildArtifacts") {
      Remove-Item "$baseDir\buildArtifacts" -Recurse -Force
    }
    mkdir "$baseDir\buildArtifacts"
}

Task Pack-Nuget -depends Clean-Artifacts -description 'Packs the modules and example packages' {
    if (Test-Path "$baseDir\buildPackages\*.nupkg") {
      Remove-Item "$baseDir\buildPackages\*.nupkg" -Force
    }

    PackDirectory "$baseDir\BuildPackages"
    PackDirectory "$baseDir\BuildScripts\nuget"
    Move-Item "$baseDir\BuildScripts\nuget\*.nupkg" "$basedir\buildArtifacts"
}

Task Package-DownloadZip -depends Clean-Artifacts {
    if (Test-Path "$basedir\BuildArtifacts\Boxstarter.*.zip") {
      Remove-Item "$basedir\BuildArtifacts\Boxstarter.*.zip" -Force
    }

    exec { ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\BuildArtifacts\Boxstarter.$version.zip" "$basedir\license.txt" }
    exec { ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\BuildArtifacts\Boxstarter.$version.zip" "$basedir\buildscripts\bootstrapper.ps1" }
    exec { ."$env:chocolateyInstall\bin\7za.bat" a -tzip "$basedir\BuildArtifacts\Boxstarter.$version.zip" "$basedir\Setup.bat" }
}

Task Deploy-DownloadZip -depends Package-DownloadZip {
    Remove-Item "$basedir\public\downloads" -Recurse -Force -ErrorAction SilentlyContinue
    mkdir "$basedir\public\downloads"
    Copy-Item "$basedir\BuildArtifacts\Boxstarter.$version.zip" "$basedir\public\downloads"
}

Task Push-Nuget -description 'Pushes the module to Myget feed' {
    PushDirectory $baseDir\buildPackages
    PushDirectory $baseDir\buildArtifacts
}

Task Push-Chocolatey -description 'Pushes the module to Chocolatey feed' {
    exec { 
        Get-ChildItem "$baseDir\buildArtifacts\*.nupkg" | 
            % { cpush $_  }
    }
}

Task Push-Codeplex {
    Add-Type -Path "$basedir\BuildScripts\CodePlexClientAPI\CodePlex.WebServices.Client.dll"
     $releaseService=New-Object CodePlex.WebServices.Client.ReleaseService
     $releaseService.Credentials = Get-Credential -Message "Codeplex credentials" -username "mwrock"
     $releaseService.CreateARelease("boxstarter","Boxstarter $version","Running the Setup.bat file will install Chocolatey if not present and then install the Boxstarter modules.",[DateTime]::Now,[CodePlex.WebServices.Client.ReleaseStatus]::Beta, $true, $true)
     $releaseFile = New-Object CodePlex.WebServices.Client.releaseFile
     $releaseFile.Name="Boxstarter $version"
     $releaseFile.MimeType="application/zip"
     $releaseFile.FileName="boxstarter.$version.zip"
     $releaseFile.FileType=[CodePlex.WebServices.Client.ReleaseFileType]::RuntimeBinary
     $releaseFile.FileData=[System.IO.File]::ReadAllBytes("$basedir\BuildArtifacts\Boxstarter.$version.zip")
     $fileList=new-object "System.Collections.Generic.List``1[[CodePlex.WebServices.Client.ReleaseFile]]"
     $fileList.Add($releaseFile)
     $releaseService.UploadReleaseFiles("boxstarter", "Boxstarter $version", $fileList)
}

task Update-Homepage {
     $downloadUrl="Boxstarter.$version.zip"
     $downloadButtonUrlPatern="Boxstarter\.[0-9]+(\.([0-9]+|\*)){1,3}\.zip"
     $downloadLinkTextPattern="V[0-9]+(\.([0-9]+|\*)){1,3}"
     $filename = "$baseDir\public\index.html"
     (Get-Content $filename) | % {$_ -replace $downloadButtonUrlPatern, $downloadUrl } | % {$_ -replace $downloadLinkTextPattern, ("v"+$version) } | Set-Content $filename
}

task Test-VM -requiredVariables "VmName","package"{
    $vm = Get-VM $VmName
    Restore-VMSnapshot $vm -Name $vm.ParentSnapshotName -Confirm:$false
    Start-VM $VmName
    $creds = Get-Credential -Message "$vmName credentials" -UserName "$env:UserDomain\$env:username"
    $me=$env:computername
    $remoteDir = $baseDir.replace(':','$')
    $encryptedPass = convertfrom-securestring -securestring $creds.password
    $modPath="\\$me\$remoteDir\Boxstarter.Chocolatey\Boxstarter.Chocolatey.psd1"
    $script = {
        Import-Module $args[0]
        Invoke-ChocolateyBoxstarter $args[1] -Password $args[2]
    }
    Write-Host "Waiting for $vmName to start..."
    do {Start-Sleep -milliseconds 100} 
    until ((Get-VMIntegrationService $vm | ?{$_.name -eq "Heartbeat"}).PrimaryStatusDescription -eq "OK")
    Write-Host "Importing Module at $modPath"
    Invoke-Command -ComputerName $vmName -Credential $creds -Authentication Credssp -ScriptBlock $script -Argumentlist $modPath,$package,$creds.Password
}

task Get-ClickOnceStats {
    $creds = Get-Credential
    mkdir "$basedir\sitelogs"
    pushd "$basedir\sitelogs"
    $ftpScript = @"
user $($creds.UserName) $($creds.GetNetworkCredential().Password)
cd LogFiles/http/RawLogs
mget *
bye
"@
    $ftpScript | ftp -i -n $ftpHost
    if(!(Test-Path $env:ChocolateyInstall\lib\logparser*)) { cinst logparser }
    $logParser = "${env:programFiles(x86)}\Log Parser 2.2\LogParser.exe"
    .$logparser -i:w3c "SELECT Date, EXTRACT_VALUE(cs-uri-query,'package') as package, COUNT(*) as count FROM * where cs-uri-stem = '/launch/Boxstarter.WebLaunch.Application' Group by Date, package Order by Date, package" -rtp:-1
    popd
    del "$basedir\sitelogs" -Recurse -Force
}

function PackDirectory($path){
    exec { 
        Get-ChildItem $path -Recurse -include *.nuspec | 
            % { .$nugetExe pack $_ -OutputDirectory $path -NoPackageAnalysis -version $version }
    }
}

function PushDirectory($path){
    exec { 
        Get-ChildItem "$path\*.nupkg" | 
            % { cpush $_ -source "http://www.myget.org/F/boxstarter/api/v2/package" }
    }
}

# Borrowed from Luis Rocha's Blog (http://www.luisrocha.net/2009/11/setting-assembly-version-with-windows.html)
function Update-AssemblyInfoFiles ([string] $version, [string] $commit) {
    $assemblyVersionPattern = 'AssemblyVersion\("[0-9]+(\.([0-9]+|\*)){1,3}"\)'
    $fileVersionPattern = 'AssemblyFileVersion\("[0-9]+(\.([0-9]+|\*)){1,3}"\)'
    $fileCommitPattern = 'AssemblyTrademark\("([a-f0-9]{40})?"\)'
    $assemblyVersion = 'AssemblyVersion("' + $version + '")';
    $fileVersion = 'AssemblyFileVersion("' + $version + '")';
    $commitVersion = 'AssemblyTrademark("' + $commit + '")';

    Get-ChildItem -path $baseDir -r -filter AssemblyInfo.cs | ForEach-Object {
        $filename = $_.Directory.ToString() + '\' + $_.Name
        $filename + ' -> ' + $version
        
        # If you are using a source control that requires to check-out files before 
        # modifying them, make sure to check-out the file here.
        # For example, TFS will require the following command:
        # tf checkout $filename
    
        (Get-Content $filename) | ForEach-Object {
            % {$_ -replace $assemblyVersionPattern, $assemblyVersion } |
            % {$_ -replace $fileVersionPattern, $fileVersion } |
            % {$_ -replace $fileCommitPattern, $commitVersion }
        } | Set-Content $filename
    }
}
