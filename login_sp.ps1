param(
  [string]$Username = $env:SP_USERNAME,
  [string]$Password = $env:SP_PASSWORD,
  [string]$Initials = $env:SP_INITIALS  # e.g. "JC"
)

if (-not $Username -or -not $Password) {
  Write-Error "Set SP_USERNAME and SP_PASSWORD."; exit 1
}

$base = 'https://www.schedulepointe.com'
$v45  = "$base/V4.5/Login2"

$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$headers = @{
  'User-Agent' = $ua
  'Accept' = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
  'Accept-Language' = 'en-US,en;q=0.9'
  'Upgrade-Insecure-Requests' = '1'
}

function Save-Text($p,$t){$t | Out-File -FilePath $p -Encoding utf8}

# robust extractor: handles single/double quotes and any attribute order
function Get-Hidden {
  param([string]$html,[string]$name)
  $nameEsc = [regex]::Escape($name)
  $rx1 = "<input\b(?:(?!>).)*(?:name|id)\s*=\s*(['""]){1}$nameEsc\1(?:(?!>).)*\bvalue\s*=\s*(['""]){1}([^'""]+)\2(?:(?!>).)*>"
  $rx2 = "<input\b(?:(?!>).)*\bvalue\s*=\s*(['""]){1}([^'""]+)\1(?:(?!>).)*(?:name|id)\s*=\s*(['""]){1}$nameEsc\3(?:(?!>).)*>"
  $m = [regex]::Match($html,$rx1,'IgnoreCase')
  if(-not $m.Success){ $m = [regex]::Match($html,$rx2,'IgnoreCase') }
  if($m.Success){ return $m.Groups[$m.Groups.Count-1].Value } else { return "" }
}

# 1) GET Login2 (collect cookies + tokens)
$resp = Invoke-WebRequest -Uri $v45 -SessionVariable session -Headers $headers -MaximumRedirection 10
$html = $resp.Content
Save-Text 'login_get_v45.html' $html

$VIEWSTATE          = Get-Hidden $html '__VIEWSTATE'
$EVENTVALIDATION    = Get-Hidden $html '__EVENTVALIDATION'
$VIEWSTATEGENERATOR = Get-Hidden $html '__VIEWSTATEGENERATOR'
if(-not $VIEWSTATE -or -not $EVENTVALIDATION){
  Write-Error "Could not extract WebForms tokens from $v45"; exit 1
}

# 2) POST creds + tokens (field names for V4.5 are Email/Password + submit control)
$body = @{
  'Email'                = $Username
  'Password'             = $Password
  'ctl04'                = 'Log in'   # submit control observed on V4.5
  '__VIEWSTATE'          = $VIEWSTATE
  '__EVENTVALIDATION'    = $EVENTVALIDATION
  '__VIEWSTATEGENERATOR' = $VIEWSTATEGENERATOR
}

$post = Invoke-WebRequest -Uri $v45 -WebSession $session -Method Post `
        -Body $body -ContentType 'application/x-www-form-urlencoded' `
        -Headers ($headers + @{ 'Referer'=$v45 }) -MaximumRedirection 10

Save-Text 'after.html' $post.Content
Write-Host ("Post redirected to: " + $post.BaseResponse.ResponseUri.AbsoluteUri)

# 3) Confirm initials menu and probe the same app path
$expected = if($Initials){$Initials}else{ ($Username.Substring(0,[Math]::Min(2,$Username.Length))).ToUpperInvariant() }
$rxProfile = '<a[^>]*\bid\s*=\s*"hypProfileMenu"[^>]*>(.*?)</a>'
$m = [regex]::Match($post.Content,$rxProfile,'IgnoreCase')
if($m.Success -and ($m.Groups[1].Value.Trim() -eq $expected)){
  Write-Host ("Login confirmed via hypProfileMenu = '"+$m.Groups[1].Value.Trim()+"'")
}else{
  Write-Warning "Did not confirm initials via hypProfileMenu in POST HTML."
}

$probe = Invoke-WebRequest -Uri "$base/V4.5/Flight.NET/Home.aspx" `
          -WebSession $session -Headers $headers -MaximumRedirection 10
$probeFinal = $probe.BaseResponse.ResponseUri.AbsoluteUri
if($probeFinal -match '(?i)/V4\.5/Login2\?ReturnUrl='){
  Write-Warning ("Probe redirected to Login2: "+$probeFinal)
}else{
  Write-Host ("Login verified via probe: "+$probeFinal)
}
