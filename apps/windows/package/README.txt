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

    Unblock-File "$env:USERPROFILE\Downloads\SkipperDesk-win-x64-0.1.6.zip"

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
3. The first time only, your browser opens so you can sign in to the SkipperDesk account
   that pays for the session. Sign in there; the page hands you back on its own, and the
   window says "Signed in as <your email>". Every later launch skips this.
4. Leave that window open. Closing it stops sharing straight away.
5. When they connect, that window asks you "Allow this computer to be controlled?" and
   shows who is asking. Type one letter and press Enter:
     y   let them in, this time only
     t   let them in, and stop asking from now on (this turns on unattended access,
         explained below)
     n   refuse
   If you do not answer within 30 seconds the connection is declined, so keep the window
   where you can see it.

If the browser does not open by itself, the window prints the address to paste into it.

While the window is open and online, this PC will not go to sleep on its own, and while
someone is connected its screen stays on too. You can still put it to sleep yourself.

Leaving the PC on its own
-------------------------
Normally every connection waits for someone at this PC to type y. If nobody will be
there, turn on unattended access: then anyone who has this PC's Device ID and Access code
connects straight away, without being asked. Only do this if you trust everyone who has
the code.

Typing t at the question above turns it on. To turn it on or off at any other time, open
PowerShell in the extracted folder (as described under "Signing out" below) and run:

    .\rc-host.exe --unattended on
    .\rc-host.exe --unattended off

The window says which one is on each time it starts, and it stays that way until you
change it. If the SkipperDesk window is already open when you run one of these, close it
and open it again so it picks up the change.

Signing out
-----------
Only if you want to stop this PC being connected to: open PowerShell in the extracted
folder (hold Shift, right-click an empty part of it, "Open PowerShell window here") and
run:  .\rc-host.exe --sign-out

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
