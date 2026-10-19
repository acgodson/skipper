SkipperDesk for Windows - private beta
======================================

This is a private beta build, shared with you personally. Please do not pass it on.
It is NOT digitally signed, so Windows will warn you about it. That is expected.

What you need
-------------
- A PC running Windows 10 or Windows 11 (64-bit).
- An internet connection.

How to open it without the warning (recommended)
------------------------------------------------
Do this BEFORE you extract the ZIP:

1. Find the ZIP file you downloaded.
2. Right-click it and choose Properties.
3. At the bottom of the General tab, tick the box called "Unblock".
   (If you do not see the box, the file is already unblocked.)
4. Click OK.
5. Now right-click the ZIP and choose "Extract All...".

If you prefer PowerShell, this does the same thing (change the path to match yours):

    Unblock-File "$env:USERPROFILE\Downloads\SkipperDesk-win-x64-0.2.0.zip"

You are only telling Windows that you trust this one file that you chose to download.
You do not need to change any Windows or antivirus settings.

If you see the blue "Windows protected your PC" screen anyway
-------------------------------------------------------------
1. Click "More info".
2. Click "Run anyway".

Running it
----------
1. Open the extracted folder and double-click rc-host.exe.
2. The SkipperDesk window opens. Under "This PC" it shows a Device ID and an Access Code,
   each with a Copy button. Give both to the person who is connecting. The pill in the
   top-right corner says "Online" once this PC can be reached.
3. The first time only, your browser opens so you can sign in to the SkipperDesk account
   that pays for the session. Sign in there; the page hands you back on its own, and the
   window shows your email under Access. Every later launch skips this. If the browser
   does not open, the window shows the address to paste into it, and "Open Browser Again"
   tries once more.
4. When someone connects, a separate SkipperDesk window pops up on top of everything,
   beeps, and asks "Allow this computer to be controlled?", showing the Device ID of the
   computer that is asking. Click one of:
     Allow                       let them in, this time only
     Allow and Don't Ask Again   let them in, and stop asking from now on (this turns on
                                 unattended access, explained below)
     Decline                     refuse (closing that window or pressing Esc does the same)
   The Allow buttons wake up a moment after the question appears, so a stray click cannot
   let anyone in. If nobody answers within 30 seconds the connection is declined.

The tray icon
-------------
SkipperDesk keeps an icon in the notification area at the bottom-right of the screen (if
you do not see it, click the small ^ arrow there). Closing the window does NOT stop
SkipperDesk: the window just hides, this PC stays reachable, and the icon stays. Click the
icon to bring the window back, or right-click it for a menu: Show window, Sign in or Sign
out, Unattended access, Copy device ID, Copy access code, Open log, and Quit.

To stop sharing, right-click the icon and choose Quit. SkipperDesk ends any session
cleanly (the other computer is told, and any key it was holding down is released) and
then closes. Starting rc-host.exe again while it is already running just brings the
window back.

While SkipperDesk is running and online, this PC will not go to sleep on its own, and
while someone is connected its screen stays on too. You can still put it to sleep
yourself.

Leaving the PC on its own
-------------------------
Normally every connection waits for someone at this PC to click Allow. If nobody will be
there, turn on unattended access: then anyone who has this PC's Device ID and Access Code
connects straight away, without being asked. Only do this if you trust everyone who has
the code.

Use the "Unattended access" switch in the window (or in the tray icon's menu), or answer
a request with "Allow and Don't Ask Again". It takes effect straight away and stays that
way until you change it.

Signing out
-----------
Only if you want to stop this PC being connected to: click "Sign Out..." in the window
(or Sign out in the tray icon's menu) and confirm. The Device ID and Access Code stay the
same; sign in again from the same place.

The log
-------
The window's Activity box shows what SkipperDesk is doing. A fuller record is kept in

    %LOCALAPPDATA%\SkipperDesk\rc-host.log

("Open Log" in the window, or Open log in the tray menu, opens it in Notepad). If
something goes wrong, sending that file to the person who gave you this build helps a
lot. It never contains your access code.

One limit worth knowing: SkipperDesk runs as you, not as an administrator, so it cannot
click inside windows that Windows itself runs with administrator rights. Ordinary apps -
your browser, File Explorer, Office, Notepad - all work normally.

Windows will ask about the network
----------------------------------
The first time you start sharing, Windows shows a box saying it has blocked some
features of the app. Choose "Allow access", and leave "Private networks" ticked.

SkipperDesk needs this to carry the picture to the other computer. If you choose
Cancel, sharing will start but the other person will never see your screen.

Removing it
-----------
Nothing is installed. Quit SkipperDesk from the tray icon and delete the folder. If you
also want to forget this PC's Device ID, delete the folder %LOCALAPPDATA%\SkipperDesk too.

Trouble?
--------
Tell the person who sent you this build what you saw on screen. A photo helps.
