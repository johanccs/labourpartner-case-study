<#
.SYNOPSIS
    Creates a demo company and login in a LOCAL LabourPartner database, for
    capturing screenshots without exposing real tenant data.

.DESCRIPTION
    The local development database contains real client company names. Screenshots
    must therefore be taken against a tenant that is provably fictional. This
    script creates one, and is idempotent so screenshots can be regenerated later.

    It refuses to run against anything that is not a local server.

.EXAMPLE
    pwsh ./seed-demo-tenant.ps1 -SqlUser sa -SqlPassword '<local password>' -WhatIf
    pwsh ./seed-demo-tenant.ps1 -SqlUser sa -SqlPassword '<local password>'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Server   = 'localhost',
    [string]$Database = 'qxcufwhe_LabourPartner',
    [Parameter(Mandatory = $true)][string]$SqlUser,
    [Parameter(Mandatory = $true)][string]$SqlPassword,
    [string]$CompanyName = 'Demo Holdings (Pty) Ltd',
    [string]$Username    = 'demo.admin',
    [string]$Password    = 'Demo!Pass123'
)

$ErrorActionPreference = 'Stop'

# --- Production guard -------------------------------------------------------
# The most important code in this file. A seeding script outlives the session it
# was written in, and the next person to run it may not read the header.

$localNames = @('localhost', '.', '(local)', '127.0.0.1', '::1')
if ($Server -notin $localNames) {
    throw "Refusing to seed: server '$Server' is not local. This script creates test data and must never touch a shared or production server."
}
if ($Database -match 'prod|azure|windows\.net') {
    throw "Refusing to seed: database name '$Database' looks like production."
}

# --- PBKDF2 hashing --------------------------------------------------------
# Must match LP.Services/Processing/LoginProcessing.cs exactly:
#   PBKDF2-SHA256, 100_000 iterations, 16-byte salt, 32-byte key,
#   stored as "pbkdf2$<iterations>$<saltB64>$<hashB64>".
# The username is NOT part of the hash input.
# A wrong KeySize produces a hash the application rejects without explanation.

function New-Pbkdf2Hash {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$Iterations = 100000,
        [int]$SaltSize   = 16,
        [int]$KeySize    = 32
    )

    $salt = [byte[]]::new($SaltSize)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)

    $key = [System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
        [System.Text.Encoding]::UTF8.GetBytes($Password),
        $salt,
        $Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        $KeySize)

    return "pbkdf2`$$Iterations`$$([Convert]::ToBase64String($salt))`$$([Convert]::ToBase64String($key))"
}

$hash = New-Pbkdf2Hash -Password $Password

# --- SQL -------------------------------------------------------------------
# Escape single quotes so a name containing an apostrophe cannot break the batch.
function Esc([string]$s) { return $s.Replace("'", "''") }

$companyEsc  = Esc $CompanyName
$usernameEsc = Esc $Username
$hashEsc     = Esc $hash

# Logins are deleted before Companies to respect the foreign key.
# CustomerType 1 / Status 0 / IsVendor 0 = an ordinary active tenant.
# The email uses the RFC 2606 reserved .invalid TLD so it can never be delivered.
$sql = @"
SET NOCOUNT ON;
BEGIN TRANSACTION;

DELETE FROM Logins  WHERE CompanyId IN (SELECT Id FROM Companies WHERE CompanyName = N'$companyEsc');
DELETE FROM Addresses WHERE CompanyId IN (SELECT Id FROM Companies WHERE CompanyName = N'$companyEsc');
DELETE FROM Companies WHERE CompanyName = N'$companyEsc';

-- Other must be '' and never NULL. The column is nullable in SQL, but the entity
-- maps it to a non-nullable string, so a NULL makes EF throw SqlNullValueException
-- ("Data is Null") on login. Every existing row uses ''.
INSERT INTO Companies (CompanyName, ContactPerson, DateRegistered, EmailAddress, Status, CompanyType, Other, CustomerType, IsVendor)
VALUES (N'$companyEsc', N'Alex Demo', SYSUTCDATETIME(), N'demo@example.invalid', 0, N'Pty(Ltd)', N'', 1, 0);

DECLARE @CompanyId INT = SCOPE_IDENTITY();

INSERT INTO Addresses (CompanyAddress, AddressLine2, AddressLine3, PostalCode, Province, City, CompanyId)
VALUES (N'1 Example Street', N'Demo Park', N'-', N'0001', N'Gauteng', N'Pretoria', @CompanyId);

INSERT INTO Logins (Username, Password, CompanyId, UserType)
VALUES (N'$usernameEsc', N'$hashEsc', @CompanyId, 1);

COMMIT TRANSACTION;

SELECT l.Id AS LoginId, l.Username, l.UserType, c.Id AS CompanyId, c.CompanyName
FROM Logins l JOIN Companies c ON c.Id = l.CompanyId
WHERE c.CompanyName = N'$companyEsc';
"@

if ($WhatIfPreference) {
    Write-Host "--- SQL that WOULD run against $Server/$Database ---" -ForegroundColor Yellow
    Write-Host $sql
    Write-Host "--- end (nothing was executed) ---" -ForegroundColor Yellow
    return
}

$sqlcmd = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe'
if (-not (Test-Path $sqlcmd)) {
    $found = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if ($null -eq $found) { throw "sqlcmd not found. Install the SQL Server command line tools." }
    $sqlcmd = $found.Source
}

$tmp = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -Path $tmp -Value $sql -Encoding UTF8
    & $sqlcmd -S $Server -U $SqlUser -P $SqlPassword -C -d $Database -i $tmp -W -s '|'
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE" }
}
finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Demo tenant ready." -ForegroundColor Green
Write-Host "  Company:  $CompanyName"
Write-Host "  Username: $Username"
Write-Host "  Password: $Password"
Write-Host ""
Write-Host "Log in via the local client to confirm the hash is accepted." -ForegroundColor Yellow
