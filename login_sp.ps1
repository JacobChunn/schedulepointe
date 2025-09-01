param(
  [string]$Username = $env:SP_USERNAME,
  [string]$Password = $env:SP_PASSWORD
)

if (-not $Username -or -not $Password) {
  Write-Error "Set SP_USERNAME and SP_PASSWORD environment variables before running."
  exit 1
}

$loginUrl = 'https://www.schedulepointe.com/signon.aspx'

# 1) GET login page; keep cookies in a session
$response = Invoke-WebRequest -Uri $loginUrl -SessionVariable session

# 2) Grab the first form and fill required fields (WebForms)
$form = $response.Forms[0]
if (-not $form) {
  Write-Error "Could not find a form on $loginUrl"
  exit 1
}

# Required hidden tokens should already be present in $form.Fields
# Add username/password and the submit control
$form.Fields['ctl00$txtSignOn']   = $Username
$form.Fields['ctl00$txtPassword'] = $Password
$form.Fields['ctl00$btnSignOn2']  = 'Sign In'

# Optional sanity checks (won't fail if missing)
foreach ($f in '__VIEWSTATE','__EVENTVALIDATION','__VIEWSTATEGENERATOR','ScriptManager1_HiddenField') {
  if (-not $form.Fields.ContainsKey($f)) {
    Write-Verbose "Warning: form field not found: $f"
  }
}

# 3) Choose post URI without using ?? (PowerShell 5.1-safe)
$postUri = $loginUrl
if ($form.Action -and $form.Action.Trim().Length -gt 0) {
  if ($form.Action.StartsWith('http')) {
    $postUri = $form.Action
  } else {
    # Handle relative action
    $postUri = [System.Uri]::new([System.Uri]$loginUrl, $form.Action).AbsoluteUri
  }
}

# 4) POST with the same session (cookies carried forward)
$postResponse = Invoke-WebRequest -Uri $postUri `
                 -WebSession $session -Method Post -Body $form.Fields -MaximumRedirection 10

# Save HTML (optional)
$outPath = Join-Path -Path (Get-Location) -ChildPath 'after.html'
$postResponse.Content | Out-File -FilePath $outPath -Encoding utf8
Write-Host ""
Write-Host "Saved response to: $outPath"

# --- Robust success checks ---

# A) Final URL from POST
$finalUri = $postResponse.BaseResponse.ResponseUri.AbsoluteUri
Write-Host "Post redirected to: $finalUri"

# B) Confirm hypProfileMenu initials in POST response
$ExpectedInitials = if ($env:SP_INITIALS) { $env:SP_INITIALS } else { ($Username.Substring(0, [Math]::Min(2, $Username.Length))).ToUpperInvariant() }
$pattern = '<a[^>]*\bid\s*=\s*"(?:hypProfileMenu)"[^>]*>(.*?)</a>'
$m = [regex]::Match($postResponse.Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if ($m.Success -and ($m.Groups[1].Value.Trim() -eq $ExpectedInitials)) {
  Write-Host "Login confirmed in POST: hypProfileMenu = '$($m.Groups[1].Value.Trim())'"
} else {
  Write-Warning "POST HTML didn't confirm initials via hypProfileMenu."
}

# C) Build a SAME-APP probe (stick with /V4.5 if that's where you landed)
$finalUriObj = [Uri]$finalUri
# Extract '/V4.5/' or '/V4/' prefix, default to '/V4.5/' if not found
$baseMatch = [regex]::Match($finalUriObj.AbsolutePath, '^/(V4(?:\.5)?)/', 'IgnoreCase')
$appBase = if ($baseMatch.Success) { "/$($baseMatch.Groups[1].Value)/" } else { "/V4.5/" }
$probeUrl = [Uri]::new($finalUriObj, $appBase + 'Flight.NET/Home.aspx').AbsoluteUri

# D) Probe with SAME session and SAME base path
$probe = Invoke-WebRequest -Uri $probeUrl -WebSession $session -MaximumRedirection 10
$probeFinal = $probe.BaseResponse.ResponseUri.AbsoluteUri
Write-Host "Probe landed at: $probeFinal"

# If we were not redirected to Login2, treat as success
$redirectedToLogin = ($probeFinal -match '(?i)/V4(\.5)?/Login2\?ReturnUrl=')
if (-not $redirectedToLogin) {
  # Optional: confirm hypProfileMenu again from the probe HTML
  $m2 = [regex]::Match($probe.Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m2.Success -and ($m2.Groups[1].Value.Trim() -eq $ExpectedInitials)) {
    Write-Host "Login verified via probe (same app). hypProfileMenu = '$($m2.Groups[1].Value.Trim())'"
  } else {
    Write-Host "Login verified via probe (same app)."
  }
} else {
  Write-Warning "Probe redirected to Login2 (different app path or session not recognized): $probeFinal"
}

