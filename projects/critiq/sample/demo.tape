# Critiq Demo GIF — vhs tape
# Shows git diff piped to critiq for AI code review

Output "assets/demo.gif"

# Set terminal appearance
Set FontSize 14
Set Width 900
Set Height 540
Set Theme "Dracula"
Set Padding 12
Set Framerate 15

# Show intro
Type "critiq"
Sleep 1s

# Clear and start
Ctrl+l
Sleep 500ms

Type "cd projects/critiq"
Sleep 200ms
Enter
Sleep 300ms

# First: show the diff we will review
Type "echo '=== Sample diff to review ==='"
Sleep 150ms
Enter
Sleep 200ms

Type "cat sample/changes.diff"
Sleep 300ms
Enter
Sleep 3s

# Now switch to the review
Ctrl+l
Sleep 300ms

Type "echo '=== Running critiq review ==='"
Sleep 150ms
Enter
Sleep 200ms

Type "node sample/demo-review.mjs sample/changes.diff"
Sleep 300ms
Enter
Sleep 4s

# Final: show the command that matters
Ctrl+l
Sleep 300ms

Type "echo '  ☆  critiq  ☆'"
Sleep 150ms
Enter
Sleep 200ms
Type "echo 'git diff HEAD | npx critiq'"
Sleep 150ms
Enter
Sleep 2s