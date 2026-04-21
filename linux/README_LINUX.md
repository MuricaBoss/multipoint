# Multipoint Bridge - Linux Client

Tämä skripti mahdollistaa Linux-järjestelmä-äänten striimaamisen Androidille.

## Esivaatimukset
Asenna tarvittavat järjestelmäpaketit (esim. Ubuntu/Debian):
```bash
sudo apt update
sudo apt install python3-pip gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-pulseaudio
```

Asenna Python-kirjastot:
```bash
pip3 install zeroconf
```

## Käyttö
Aja skripti terminaalissa:
```bash
python3 multipoint_linux.py
```

## Miten se toimii
Skripti käyttää GStreameriä lukeakseen audion PulseAudio/PipeWire-monitorista. Se hakee automaattisesti Android-vastaanottimen mDNS-palvelun avulla.

Jos automaattihaku ei toimi, skripti kysyy IP-osoitetta manuaalisesti.
