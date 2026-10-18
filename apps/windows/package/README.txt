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

    Unblock-File "$env:USERPROFILE\Downloads\SkipperDesk-win-x64-0.1.3.zip"

You are only telling Windows that you trust this one file that you chose to download.
You do not need to change any Windows or antivirus settings.

If you see the blue "Windows protected your PC" screen anyway
-------------------------------------------------------------
1. Click "More info".
2. Click "Run anyway".

Running it
----------
1. Open the extracted folder and double-click rc-host.exe.
2. A window opens showing a Device ID and an Access code. Give both to the person who is
   connecting.
3. Leave that window open. Closing it stops sharing straight away.
4. When they connect, that window asks you "Allow this computer to be controlled?" and
   shows who is asking. Type y and press Enter to let them in, or n to refuse. If you do
   not answer within 30 seconds the connection is declined, so keep the window where you
   can see it.

Signing in (once, before the first connection)
----------------------------------------------
This PC has to be signed in to the SkipperDesk account that is paying for the session, or
the connection is refused before it starts.

1. Run the host once (step 1 above) so it can get its Device ID, then close it.
2. Open the extracted folder, hold Shift and right-click an empty part of it, choose
   "Open PowerShell window here", and run:  .\rc-host.exe --sign-in
3. Your browser opens. Sign in. The page hands you back to the app automatically.
4. It prints "Signed in as <your email>". You can close that window and go back to step 1.

To sign this PC out again:  .\rc-host.exe --sign-out

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
Nothing is installed. Close the window and delete the folder. That is all.

Trouble?
--------
Tell the person who sent you this build what you saw on screen. A photo helps.
