# Rocketsled Server

The website a PaaS's customers use: Fauxroku or Fauxcel, picked by the `PAAS` environment variable. Its image is Rocketsled with this example's configs and skins inside, built by `./bootstrap.sh servers`.

Set the PaaS's three secrets on its instance. Set `PAAS`, `MASSDRIVER_ORGANIZATION_ID` and the PaaS's base URL under **Environment variables**.
