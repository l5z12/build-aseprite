@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSReviewUnusedParameter',
        'PSAvoidUsingEmptyCatchBlock',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns'
    )
}
