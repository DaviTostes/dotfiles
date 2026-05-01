function toggle-claude
  set window (hyprctl clients -j | jq -r '.[] | select(.class | test("claude"; "i")) | .address')
  
  if test -n "$window"
      hyprctl dispatch focuswindow address:$window
  else
      claude-desktop &
  end
end
