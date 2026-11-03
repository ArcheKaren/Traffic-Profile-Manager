function Get-TpmTestAclSignature([string]$Path) {
    $acl=Get-Acl -LiteralPath $Path
    $sidType=[Security.Principal.SecurityIdentifier]
    $rules=@($acl.GetAccessRules($true,$true,$sidType) | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.IdentityReference.Value,$_.AccessControlType,[int]$_.FileSystemRights,[int]$_.InheritanceFlags,[int]$_.PropagationFlags,$_.IsInherited
    } | Sort-Object)
    # Compare ownership, inheritance protection and access rules, independent of SDDL ordering.
    $value=@($acl.GetOwner($sidType).Value,$acl.GetGroup($sidType).Value,[string]$acl.AreAccessRulesProtected)+$rules
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($value -join [Environment]::NewLine)))).Replace('-','') }
    finally { $sha.Dispose() }
}
