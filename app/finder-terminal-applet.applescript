-- Finder Terminal helper app. Built by install.sh with osacompile.
-- It exists so macOS has a real app to grant Accessibility and Automation to;
-- Automator's hidden Quick Action runner cannot be granted Accessibility.
--   open -a "Finder Terminal.app"            -> toggle, front Finder window's folder
--   open -a "Finder Terminal.app" <folder>   -> toggle in that folder

property launcher : "__FINDER_TERMINAL_BIN__"

on run
	my toggle("")
end run

on open theItems
	set theFolder to ""
	repeat with i in theItems
		set theFolder to POSIX path of i
		exit repeat
	end repeat
	my toggle(theFolder)
end open

on toggle(theFolder)
	set cmd to quoted form of launcher & " toggle"
	if theFolder is not "" then set cmd to cmd & " " & quoted form of theFolder
	try
		do shell script cmd
	on error msg number errNum
		if errNum is 3 then
			activate
			set r to display dialog "Finder Terminal needs Accessibility access to place the Ghostty window under Finder." & return & return & "System Settings > Privacy & Security > Accessibility: turn on \"Finder Terminal\", then run the action again." buttons {"Open Settings", "OK"} default button "Open Settings" with icon caution
			if button returned of r is "Open Settings" then
				do shell script "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
			end if
		else
			activate
			display dialog "Finder Terminal failed:" & return & msg buttons {"OK"} default button "OK" with icon stop
		end if
	end try
end toggle
