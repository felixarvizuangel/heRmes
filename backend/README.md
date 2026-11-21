# Backend heRmes (Django)

La base `db.sqlite3` NO está en el repositorio (contiene el usuario admin).
Para crearla desde cero:

```powershell
cd backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
python manage.py migrate
python manage.py poblar_uth --json edificios_uth.json   # 23 edificios trazados sobre satélite
python manage.py cargar_accesos                          # puertas (aproximadas de OSM)
python manage.py importar_andadores                      # grafo de andadores para las rutas
python manage.py createsuperuser                         # tu propio admin
python manage.py runserver 0.0.0.0:8000
```

Pruebas: `python manage.py test`
