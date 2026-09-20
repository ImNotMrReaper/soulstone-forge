================================================================================
                    SOUL STONE ENCRYPTED COMPANION DRIVE
================================================================================

This drive is a high-performance modular companion storage device protected with 
LUKS2 hardware encryption (AES-XTS-512 / Argon2id) and Btrfs transparent compression.

Your files live safely in Partition 2. This FAT32 partition (SOUL_BOOT) contains 
the unlock tools so this drive works seamlessly across BOTH Windows and Linux.

--------------------------------------------------------------------------------
1. HOW TO USE ON LINUX (Ubuntu, Debian, Fedora, Arch, Steam Deck, etc.)
--------------------------------------------------------------------------------
• Standard GUI Access:
  Simply plug the card into any Linux PC. Your file manager (Nautilus, Dolphin, 
  Thunar, etc.) will detect the encrypted partition and prompt for your password:
    Default Passphrase: [ soulkeeper ]

• Automatic Home Directory Overlays (Full Soul Stone Integration):
  If you want this Linux PC to automatically bind-mount your companion folders 
  (Downloads, Documents, Pictures, Projects, Games, etc.) into your home folder:
  1. Open Terminal in this folder.
  2. Run:
       sudo bash install_linux.sh

--------------------------------------------------------------------------------
2. HOW TO USE ON WINDOWS (Windows 10 / Windows 11)
--------------------------------------------------------------------------------
• 1-Click Method (WSL2):
  1. Right-click 'Unlock_On_Windows.bat' and select "Run as administrator".
  2. Enter the PhysicalDrive number shown on screen.
  3. Windows File Explorer will automatically open to your files inside \\wsl$\...
  
• When finished on Windows:
  Open PowerShell as Administrator and run:
    wsl --unmount \\.\PHYSICALDRIVE<N>

--------------------------------------------------------------------------------
3. OPEN-SOURCE & CUSTOMIZATIONS
--------------------------------------------------------------------------------
Soul Stone Forge is fully open source. Anyone can build, clone, or customize 
their own companion drives:
  GitHub: https://github.com/ImNotMrReaper/soulstone-forge
================================================================================
