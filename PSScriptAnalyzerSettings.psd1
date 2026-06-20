@{
    Severity = @('Error', 'Warning')

    # Script parameters are consumed by functions in script scope; the analyzer
    # does not follow those references. PowerShell 7 reads UTF-8 without a BOM.
    ExcludeRules = @(
        'PSReviewUnusedParameter'
        'PSUseBOMForUnicodeEncodedFile'
    )
}
