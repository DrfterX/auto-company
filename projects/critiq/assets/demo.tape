Output assets/demo.gif
Set FontSize 14
Set Width 960
Set Height 540
Set Theme Dracula
Set TypingSpeed 80ms
Set Framerate 15
Require 500ms

# Show intro
Write " # Critiq — Zero-noise AI Code Review"
Sleep 200ms
Enter
Sleep 300ms
Write " # Pipe git diff | critiq and catch real bugs before they ship"
Sleep 200ms
Enter
Sleep 1000ms

# Show the diff
Write " cat assets/sample.diff"
Sleep 200ms
Enter

# Wait for cat output to appear
Sleep 2000ms

# Run critiq review
Write " bash assets/demo-mock-review.sh"
Sleep 200ms
Enter

# Wait for mock output to render
Sleep 3500ms

# Hold on final screen
Sleep 4000ms