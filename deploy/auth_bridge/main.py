import os
import requests
from fastapi import FastAPI, Request, Response, HTTPException

app = FastAPI()

LITELLM_API_BASE = os.getenv("LITELLM_API_BASE", "http://10.75.0.3:4000")

@app.get("/health")
def health():
    return {"status": "healthy"}

@app.get("/validate")
async def validate(request: Request, response: Response):
    # Intercepta as credenciais de autenticação básica enviadas pelo navegador na tela de login
    auth_header = request.headers.get("Authorization")
    if not auth_header:
        # Se não houver credencial, desafia o navegador com pop-up HTTP Basic Auth
        response.headers["WWW-Authenticate"] = 'Basic realm="Acesso Portal de IA do ONR - Use seu login do LiteLLM"'
        raise HTTPException(status_code=401, detail="Autenticação requerida")
    
    # Repassa as credenciais de usuário/senha para a API de autenticação do portal LiteLLM
    # No LiteLLM corporativo, a rota padrão de validação de login e chaves de admin usa /user/info ou /key/info
    try:
        # Efetuamos a validação de credenciais de usuário
        # O LiteLLM utiliza basic auth ou bearer tokens. Traduzimos as credenciais de login para a API do LiteLLM
        litellm_url = f"{LITELLM_API_BASE}/user/info"
        headers = {"Authorization": auth_header}
        
        litellm_response = requests.get(litellm_url, headers=headers, timeout=5)
        
        if litellm_response.status_code == 200:
            user_data = litellm_response.json()
            # Se o usuário e senha são válidos no LiteLLM, repassamos os metadados dele para o Open WebUI logar
            # Garantimos que os cabeçalhos confiáveis (Trusted Headers) sejam preenchidos
            user_email = user_data.get("user_email") or f"{user_data.get('user_id', 'usuario_ia')}@onr.org.br"
            user_name = user_data.get("user_id") or "Colaborador ONR"
            
            response.headers["X-User-Email"] = user_email
            response.headers["X-User-Name"] = user_name
            return {"status": "authenticated"}
        else:
            raise HTTPException(status_code=401, detail="Credenciais LiteLLM inválidas")
            
    except requests.exceptions.RequestException:
        # Fallback de segurança: Caso o LiteLLM esteja indisponível, barramos a entrada
        raise HTTPException(status_code=503, detail="Serviço de autenticação LiteLLM temporariamente inacessível")
