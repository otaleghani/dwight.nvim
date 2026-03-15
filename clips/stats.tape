# Stats: usage trends and success rates
# Needs pre-populated .dwight/usage.json
Output stats.gif

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

Type ":DwightStats"
Sleep 800ms
Enter
Sleep 2.5s

Sleep 2s

Type ":DwightStats features"
Sleep 800ms
Enter
Sleep 2.5s

Sleep 3s
