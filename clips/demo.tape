# Output file and visual settings
Output dwight_demo.gif
Set Theme "Catppuccin Mocha"
Set Width 1200
Set Height 800
Set Padding 20
Set FontSize 18

# 1. Open a sample file in Neovim
Type "nvim example.txt"
Enter
Sleep 1.5s

# 2. Select all text (gg = go to top, V = visual line mode, G = go to bottom)
Type "ggVG"
Sleep 1s

# 3. Call your plugin command
Type ":DwightInvoke"
Sleep 500ms
Enter

# 4. Leave it on the screen so viewers can see the result
Sleep 4s
