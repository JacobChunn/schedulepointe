param(
  [string]$Username = $env:SP_USERNAME,
  [string]$Password = $env:SP_PASSWORD
)

if (-not $Username -or -not $Password) {
  Write-Error "Set SP_USERNAME and SP_PASSWORD environment variables before running."
  exit 1
}

$loginUrl = 'https://www.schedulepointe.com/signon.aspx'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36'

# 1) GET signon.aspx and keep cookies in a session
$response = Invoke-WebRequest -Uri $loginUrl -SessionVariable session -Headers @{ 'User-Agent' = $ua }

$html = $response.Content

function Get-Hidden {
  param([string]$name)
  $m = [regex]::Match($html, "name=`"$([regex]::Escape($name))`"\s+value=`"([^`"]*)`"", 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value } else { return "" }
}

# 2) Extract current WebForms tokens from the HTML (PS7 has no .Forms)
$VIEWSTATE          = Get-Hidden '__VIEWSTATE'
$VIEWSTATEGENERATOR = Get-Hidden '__VIEWSTATEGENERATOR'
$EVENTVALIDATION    = Get-Hidden '__EVENTVALIDATION'
$SCRIPTMANAGER      = Get-Hidden 'ScriptManager1_HiddenField'

if (-not $VIEWSTATE -or -not $EVENTVALIDATION) {
  Write-Error "Could not extract __VIEWSTATE / __EVENTVALIDATION from $loginUrl"
  exit 1
}

# 3) Build the POST body (key names include $ so use quoted hashtable keys)
$body = @{
  'ctl00$txtSignOn'        = $Username
  'ctl00$txtPassword'      = $Password
  'ctl00$btnSignOn2'       = 'Sign In'
  '__EVENTTARGET'          = ''
  '__EVENTARGUMENT'        = ''
  '__VIEWSTATE'            = $VIEWSTATE
  '__VIEWSTATEGENERATOR'   = $VIEWSTATEGENERATOR
  '__EVENTVALIDATION'      = $EVENTVALIDATION
}
if ($SCRIPTMANAGER) { $body['ScriptManager1_HiddenField'] = $SCRIPTMANAGER }

# 4) POST back with same session (cookies)
$postResponse = Invoke-WebRequest -Uri $loginUrl `
  -WebSession $session -Method Post -Body $body `
  -ContentType 'application/x-www-form-urlencoded' `
  -Headers @{ 'User-Agent' = $ua; 'Origin'='https://www.schedulepointe.com'; 'Referer'=$loginUrl } `
  -MaximumRedirection 10

# 5) Save HTML for inspection
$outPath = Join-Path (Get-Location) 'after.html'
$postResponse.Content | Out-File -FilePath $outPath -Encoding utf8
Write-Host "Saved response to: $outPath"

# 6) Robust success checks:
$finalUri = $postResponse.BaseResponse.ResponseUri.AbsoluteUri
Write-Host "Post redirected to: $finalUri"

# Confirm the profile initials anchor appears
$expectedInitials = if ($env:SP_INITIALS) { $env:SP_INITIALS } else { ($Username.Substring(0,[Math]::Min(2,$Username.Length))).ToUpperInvariant() }
$profileMatch = [regex]::Match($postResponse.Content, '<a[^>]*\bid\s*=\s*"hypProfileMenu"[^>]*>(.*?)</a>', 'IgnoreCase')
if ($profileMatch.Success -and ($profileMatch.Groups[1].Value.Trim() -eq $expectedInitials)) {
  Write-Host "Login confirmed via hypProfileMenu = '$($profileMatch.Groups[1].Value.Trim())'"
} else {
  Write-Warning "Did not confirm initials via hypProfileMenu in POST HTML."
}

# Probe using the same app base (V4 vs V4.5)
$finalUriObj = [Uri]$finalUri
$baseMatch = [regex]::Match($finalUriObj.AbsolutePath, '^/(V4(?:\.5)?)/', 'IgnoreCase')
$appBase = if ($baseMatch.Success) { "/$($baseMatch.Groups[1].Value)/" } else { "/V4.5/" }
$probeUrl = [Uri]::new($finalUriObj, $appBase + 'Flight.NET/Home.aspx').AbsoluteUri

$probe = Invoke-WebRequest -Uri $probeUrl -WebSession $session -Headers @{ 'User-Agent' = $ua } -MaximumRedirection 10
$probeFinal = $probe.BaseResponse.ResponseUri.AbsoluteUri
if ($probeFinal -match '(?i)/V4(\.5)?/Login2\?ReturnUrl=') {
  Write-Warning "Probe redirected to Login2: $probeFinal"
} else {
  Write-Host "Login verified via probe: $probeFinal"
}
