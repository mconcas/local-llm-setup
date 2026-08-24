FROM python:3.12-alpine
COPY exporter.py /exporter.py
EXPOSE 9101
USER 65534:65534
ENTRYPOINT ["python", "/exporter.py"]
