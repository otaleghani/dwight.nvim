# Coverage: tagged vs untagged source files
Output coverage.gif

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

Type ":DwightCoverage"
Sleep 800ms
Enter
Sleep 3s

Sleep 3s
