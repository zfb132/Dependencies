param([string]$Configuration, [string]$Platform, [string]$Version)

function Get-PeviewBinary {
  param(
    [String] $BuildVersion,
    [String] $Hash
  )

  Push-Location;
  $PeviewBinaryFile = "";

  # use temporary folder for download
  New-Item -ItemType Directory -Force -Path "$($env:TEMP)/tmp";
  Set-Location "$($env:TEMP)/tmp"

  $apiUrl = "https://github.com/winsiderss/si-builds/releases/download/$BuildVersion";
  $artifactFileName = "systeminformer-$BuildVersion-bin.zip";

  # get the zip file job artifacts
  Invoke-WebRequest -Uri "$apiUrl/$artifactFileName" -OutFile "./$artifactFileName"

  # get the platform subfolder within the artifact zip file
  $pePlatform = "i386"
  if ($env:platform -eq "x64") {
    $pePlatform = "amd64"
  }

  # check the expected hash before extracing binaries
  $PhArchiveHash = (Get-FileHash -Algorithm SHA256 -Path "./$artifactFileName").Hash;
  if ($PhArchiveHash -eq $Hash) {
    &7z.exe x "./$artifactFileName" "$($pePlatform)/peview.exe";
    $PeviewBinaryFile = (Resolve-Path "./$($pePlatform)/peview.exe").Path;
  }

  # Because of wacky Powershell "return" behavior, it's better to store the result in a env variable.
  $env:PEVIEW_PATH = $PeviewBinaryFile;
  Pop-Location;
}

function Copy-SystemDll {
  param(
    [String] $DllName,
    [String] $OutputFolder
  )

  $SystemFolder = [System.Environment]::GetFolderPath('SystemX86');
  if ($env:platform -eq "x64")
  {
    # Check if it's a 32-bit powershell application, in order to force accessing System32
    if (Test-path "$([System.Environment]::GetFolderPath('Windows'))\sysnative")
    {
      $SystemFolder = "$([System.Environment]::GetFolderPath('Windows'))\sysnative";
    }
    else
    {
      $SystemFolder = [System.Environment]::GetFolderPath('System');
    }
  }

  $DllPath="$($SystemFolder)\$($DllName)";
  if (Test-Path $DllPath) {
    Write-Host "Copy system dll $((Resolve-Path $DllPath).Path)";
    Copy-Item (Resolve-Path $DllPath).Path -Destination $OutputFolder;
  }
}


function Copy-UniversalCrt {
  param(
    [String] $OutputFolder
  )

  # reference : https://github.com/mozilla/gecko-dev/blob/50b3fb522bdb080a7c9c00b1fdc758d171586cb6/media/webrtc/trunk/webrtc/build/vs_toolchain.py#L203
  $UcrtFolder = "C:\Program Files (x86)\Windows Kits\10\Redist\ucrt\DLLs\$($env:platform)";
  
  foreach ($ucrtdll in gci $UcrtFolder -File) {
    Write-Host "Copy ucrt dll $($ucrtdll.FullName)";
    Copy-Item $ucrtdll.FullName -Destination $OutputFolder;
  }
}

function Get-DependenciesDeps {
  param(
    [String] $Binpath,
    [String] $OutputFolder
  )

  # Download external dependencies like peview
  $PeBuildVersion = "3.0.7422";
  $PeviewBuildHash = "F6A8C347847C97294A3141A0115CA1E883109E639663C6F716DC90F03E2DC78D";
  Get-PeviewBinary -BuildVersion $PeBuildVersion -Hash $PeviewBuildHash;
  if (-not $env:PEVIEW_PATH)
  {
    Write-Error "[x] Peview binary has not correctly been downloaded."
  }


  # Bundling dbghelp.dll along for undecorating names
  Copy-SystemDll -DllName "dbghelp.dll" -OutputFolder $OutputFolder;

  # Bundling every msvc redistribuables
  $ClrPhLibPath = "$($Binpath)/ClrPhLib.dll";
  $ClrPhLibImports = &"$($Binpath)/Dependencies.exe" -json -imports $ClrPhLibPath | ConvertFrom-Json;
  foreach($DllImport in $ClrPhLibImports.Imports) {
    
    # vcruntime
    if ($DllImport.Name.ToLower().StartsWith("vcruntime"))
    {
      Copy-SystemDll -DllName $DllImport.Name -OutputFolder $OutputFolder;
    }

    # msvc
    if ($DllImport.Name.ToLower().StartsWith("msvc"))
    {
      Copy-SystemDll -DllName $DllImport.Name -OutputFolder $OutputFolder;
    }

    # ucrtbase
    if ($DllImport.Name.ToLower().StartsWith("ucrtbase"))
    {
      Copy-SystemDll -DllName $DllImport.Name -OutputFolder $OutputFolder;
    }

     # concrt
    if ($DllImport.Name.ToLower().StartsWith("concrt"))
    {
      Copy-SystemDll -DllName $DllImport.Name -OutputFolder $OutputFolder;
    }

  }

  # Packaging universal CRT on Release builds
  if ($($env:CONFIGURATION) -eq "Release") {
    Copy-UniversalCrt -OutputFolder $OutputFolder;
  }

  return [string]$PeviewBinaryFile;
}

function Run-RegressTests {
  param(
    [String] $Binpath
  )

  Write-Host "Test if the binary (and the underlying lib) actually works"
  
  Write-Host "Test basic functionnality"
  &"$($Binpath)/Dependencies.exe" -knowndll
  &"$($Binpath)/Dependencies.exe" -apisets
  &"$($Binpath)/Dependencies.exe" -sxsentries "$($env:windir)/System32/ctfmon.exe" 


  Write-Host "Test manifest parsing"
  ./test/manifest-regress/Test-ManifestRegress.ps1 $($Binpath)

  # deactivated since it's too long
  # &"$BINPATH/demangler-test.exe"

  Write-Host "Tests done."
}

# Setting up environment variables
$env:CONFIGURATION = $Configuration;
$env:platform = $Platform;

$BINPATH="$PSScriptRoot/bin/$($env:CONFIGURATION)$($env:platform)";
$DepsFolder="$PSScriptRoot/deps/$($env:CONFIGURATION)$($env:platform)";
$OutputFolder="$PSScriptRoot/output";

# Creating output directory
New-Item -ItemType Directory -Force -Path $DepsFolder;
New-Item -ItemType Directory -Force -Path $OutputFolder;


# Retrieve all dependencies that need to be packaged
Get-DependenciesDeps -Binpath $BINPATH -OutputFolder $DepsFolder;

# Running regress tests
Run-RegressTests -Binpath $BINPATH;


Write-Host "Zipping everything"
if ($($env:CONFIGURATION) -eq "Debug") {
	&7z.exe a "$($OutputFolder)/Dependencies_$($Version)_$($env:platform)_$($env:CONFIGURATION).zip" $BINPATH/tests $BINPATH/*.dll $BINPATH/*.exe $BINPATH/*.config $BINPATH/*.pdb $DepsFolder/* $env:PEVIEW_PATH;
}
else {
	&7z.exe a "$($OutputFolder)/Dependencies_$($Version)_$($env:platform)_$($env:CONFIGURATION).zip" $BINPATH/*.dll $BINPATH/*.exe $BINPATH/*.config $BINPATH/*.pdb $DepsFolder/* $env:PEVIEW_PATH;
	&7z.exe a "$($OutputFolder)/Dependencies_$($Version)_$($env:platform)_$($env:CONFIGURATION)_(without peview.exe).zip" $BINPATH/*.dll $BINPATH/*.exe $BINPATH/*.config $BINPATH/*.pdb $DepsFolder/*;
}

# APPX packaging
<#if (( $($env:CONFIGURATION) -eq "Release") -and ($env:APPVEYOR_REPO_TAG)) {
  $makeappx = "${env:ProgramFiles(x86)}\Windows Kits\10\App Certification Kit\makeappx.exe";
  $signtool = "${env:ProgramFiles(x86)}\Windows Kits\10\App Certification Kit\signtool.exe";

  # Copy assets to build folder
  Copy-Item "$PSScriptRoot/DependenciesAppx/Assets" -Destination "$PSScriptRoot/bin/Appx_$($env:CONFIGURATION)$($env:platform)" -Force -Recurse

  # Create appx package
  & $makeappx pack /d "$PSScriptRoot/bin/Appx_$($env:CONFIGURATION)$($env:platform)" /l /p "$PSScriptRoot/bin/Appx_$($env:CONFIGURATION)$($env:platform).appx"

  # Sign appx package
  & $signtool sign /fd SHA256 /a /f "$PSScriptRoot/DependenciesAppx/DependenciesAppx_TemporaryKey.pfx" "$PSScriptRoot/bin/Appx_$($env:CONFIGURATION)$($env:platform).appx"
}#>