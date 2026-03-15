# Whiteboard: brainstorm and save ideas
Output whiteboard.gif

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontSize 18
Set Padding 20
Set TypingSpeed 60ms
Set WindowBar Colorful
Set Width 1200
Set Height 800

Type "cd sample-project && nvim init.lua"
Enter
Sleep 1.5s

Type ":DwightWhiteboard"
Sleep 800ms
Enter
Sleep 1.5s

Type "i"
Sleep 300ms
Type "# Refactoring Plan"
Enter
Enter
Type "1. Extract config validation into separate module"
Enter
Type "2. Add retry logic to HTTP client"
Enter
Type "3. Unify error handling across modules"
Enter
Enter
Type "## Notes"
Enter
Type "- Keep backward compat with existing configs"
Enter
Type "- Add migration warnings for deprecated keys"
Escape
Sleep 2s

Type ":DwightWhiteboardSave refactor-plan"
Sleep 800ms
Enter
Sleep 2s

Sleep 3s
