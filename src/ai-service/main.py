import os
from fastapi import FastAPI, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from routers.description_generator import description
from routers.image_generator import image

app = FastAPI(version=os.environ.get("APP_VERSION", "0.1.0"))
app.include_router(description)
app.include_router(image)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

@app.get("/health", summary="check if server is healthy", operation_id="health")
async def get_health():
    capabilities = ["description"]

    use_azure = os.environ.get("USE_AZURE_OPENAI", "False").lower() == "true"

    if use_azure:
        has_image = (
            (os.environ.get("AZURE_OPENAI_DALLE_ENDPOINT") or os.environ.get("AZURE_OPENAI_ENDPOINT"))
            and os.environ.get("AZURE_OPENAI_DALLE_DEPLOYMENT_NAME")
        )
    else:
        # ✅ plain OpenAI — just need the API key
        has_image = bool(os.environ.get("OPENAI_API_KEY"))

    if has_image:
        capabilities.append("image")

    print("Generative AI capabilities: ", ", ".join(capabilities))
    return JSONResponse(
        content={"status": "ok", "version": app.version, "capabilities": capabilities},
        status_code=status.HTTP_200_OK
    )