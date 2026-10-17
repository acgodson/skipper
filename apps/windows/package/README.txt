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

    Unblock-File "$env:USERPROFILE\Downloads\SkipperDesk-win-x64.zip"

You are only telling Windows that you trust this one file that you chose to download.
You do not need to change any Windows or antivirus settings.

If you see the blue "Windows protected your PC" screen anyway
-------------------------------------------------------------
1. Click "More info".
2. Click "Run anyway".

Running it
----------
1. Open the extracted folder and double-click rc-host.exe.
2. Windows will ask whether to allow the app to make changes. Choose Yes. This is needed so
   the app can work with every window on your screen.
3. A window opens showing a Device ID and an Access code. Give both to the person who is
   connecting.
4. Leave that window open. Closing it stops sharing straight away.

Removing it
-----------
Nothing is installed. Close the window and delete the folder. That is all.

Trouble?
--------
Tell the person who sent you this build what you saw on screen. A photo helps.
