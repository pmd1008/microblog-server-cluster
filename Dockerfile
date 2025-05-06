FROM python:3.9
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
EXPOSE 5000 9100
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "microblog:app"]
