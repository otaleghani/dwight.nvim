" Syntax highlighting for dwight prompt buffer (fallback — live extmarks do the real work)

if exists("b:current_syntax")
  finish
endif

syn match dwightSkillToken /@[a-zA-Z0-9_\-\.]\+/
syn match dwightModeToken /\/\(document\|refactor\|optimize\|fix\|security\|explain\|brainstorm\|plan\|code\|test\|stub\|tdd\|lint\|macro\)\>/
syn match dwightSymbolToken /#[a-zA-Z0-9_\-\.]\+/
syn match dwightModelToken /![a-zA-Z0-9_\-\./:]\+/
syn match dwightFeatureToken /\$[a-zA-Z0-9_\-\.]\+/
syn match dwightThinkToken /\^[0-9]\+/
syn match dwightLibToken /%[a-zA-Z0-9_\-\.]\+/
syn match dwightMcpToken /&[a-zA-Z0-9_\-\./:]\+/
syn match dwightFileToken /+[a-zA-Z0-9_\-\.\/]\+/
syn match dwightAuditToken /\~audit\(:[a-zA-Z0-9_\-\./:]\+\)\?/
syn match dwightSeparator /^[─═┌└│┐┘].*$/
syn match dwightInfoLabel /^\s*\(model\|skills\|modes\):/

hi def link dwightSkillToken DwightSkill
hi def link dwightModeToken DwightMode
hi def link dwightSymbolToken DwightSymbol
hi def link dwightModelToken DwightModel
hi def link dwightFeatureToken DwightFeature
hi def link dwightThinkToken DwightThink
hi def link dwightLibToken DwightLib
hi def link dwightMcpToken DwightMcp
hi def link dwightFileToken DwightFile
hi def link dwightAuditToken DwightAudit
hi def link dwightSeparator Comment
hi def link dwightInfoLabel Comment

let b:current_syntax = "dwight_prompt"
