# Multipoint Bridge - Windows Client

Tämä sovellus sallii Windows-järjestelmä-äänten striimaamisen Android-puhelimeen ultra-matalalla viiveellä.

## Esivaatimukset
1. **.NET 8 SDK**: Lataa ja asenna [dotnet.microsoft.com](https://dotnet.microsoft.com/en-us/download/dotnet/8.0).
2. **Koneet samassa verkossa**.

## Kääntö ja ajaminen
1. Kopioi `windows`-kansio Windows-koneellesi.
2. Avaa **PowerShell** tai **Command Prompt** tuossa kansiossa.
3. Aja seuraava komento käännettäksesi ja käynnistääksesi sovelluksen:
   ```cmd
   dotnet run
   ```

## Miten se toimii
- Sovellus käyttää **WASAPI Loopback** -tekniikkaa, kaapaten kaiken äänen (Spotify, YouTube, Pelit jne.).
- Se etsii automaattisesti verkosta puhelimesi, jossa on Multipoint-sovellus päällä.
- Ääni lähetetään paketoimattomana PCM-striiminä UDP-porttiin 9999.

## Jos haluat tehdä EXE-tiedoston
Voit luoda yhden itsenäisen `.exe`-tiedoston komennolla:
```cmd
dotnet publish -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true
```
Tämän jälkeen löydät valmiin ohjelman kansiosta:
`bin\Release\net8.0-windows\win-x64\publish\MultipointBridgeWin.exe`
