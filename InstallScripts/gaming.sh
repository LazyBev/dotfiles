paru -S vesktop-bin steam wine 
git clone https://github.com/NelloKudo/osu-winello.git  
cd osu-winello  
chmod +x osu-winello.sh  
./osu-winello.sh  
git clone https://aur.archlinux.org/opentabletdriver.git  
cd opentabletdriver  
makepkg -si  
cd ~ 
sudo rm -rf opentabletdriver  
sudo mkinitcpio -P  
sudo rmmod wacom hid_uclogic
