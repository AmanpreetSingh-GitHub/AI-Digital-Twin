from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import os
from dotenv import load_dotenv
from typing import Optional, List, Dict
import json
import uuid
from datetime import datetime
import boto3
from botocore.exceptions import ClientError
from context import prompt
from openai import OpenAI

# Load environment variables
load_dotenv()

app = FastAPI()

# Configure CORS
origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# Initialize Bedrock client - see Q42 on https://edwarddonner.com/faq if the Region gives you problems
#bedrock_client = boto3.client(service_name="bedrock-runtime", region_name=os.getenv("DEFAULT_AWS_REGION", "us-east-1"))

# Bedrock model selection - see Q42 on https://edwarddonner.com/faq for more
#BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "global.amazon.nova-2-lite-v1:0")

openai_client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5-mini")

# Memory storage configuration
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

# Initialize S3 client if needed
if USE_S3:
    s3_client = boto3.client("s3")


# Request/Response models
class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


class Message(BaseModel):
    role: str
    content: str
    timestamp: str


# Memory management functions
def get_memory_path(session_id: str) -> str:
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    """Load conversation history from storage"""
    if USE_S3:
        try:
            response = s3_client.get_object(Bucket=S3_BUCKET, Key=get_memory_path(session_id))
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise
    else:
        # Local file storage
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        if os.path.exists(file_path):
            with open(file_path, "r") as f:
                return json.load(f)
        return []


def save_conversation(session_id: str, messages: List[Dict]):
    """Save conversation history to storage"""
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
    else:
        # Local file storage
        os.makedirs(MEMORY_DIR, exist_ok=True)
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        with open(file_path, "w") as f:
            json.dump(messages, f, indent=2)


# def call_bedrock(conversation: List[Dict], user_message: str) -> str:
#     """Call AWS Bedrock with conversation history"""
    
#     # Build messages in Bedrock format
#     messages = []
    
#     # Add conversation history (limit to last 25 exchanges)
#     for msg in conversation[-50:]:
#         messages.append({
#             "role": msg["role"],
#             "content": [{"text": msg["content"]}]
#         })
    
#     # Add current user message
#     messages.append({
#         "role": "user",
#         "content": [{"text": user_message}]
#     })
    
#     try:
#         response = bedrock_client.converse(
#             modelId=BEDROCK_MODEL_ID,
#             system=[{"text": prompt()}],
#             messages=messages,
#             inferenceConfig={
#                 "maxTokens": 2000,
#                 "temperature": 0.7
#             }
#         )
        
#         return response["output"]["message"]["content"][0]["text"]
        
#     except ClientError as e:
#         error_code = e.response["Error"]["Code"]
#         error_message = e.response["Error"]["Message"]

#         print(f"Bedrock error code: {error_code}")
#         print(f"Bedrock error message: {error_message}")

#         raise HTTPException(
#             status_code=500,
#             detail=f"{error_code}: {error_message}"
#         )

def call_openai(conversation: List[Dict], user_message: str) -> str:
    """Call OpenAI with conversation history"""

    messages = []

    # Add conversation history (last 50 messages)
    for msg in conversation[-50:]:
        messages.append({
            "role": msg["role"],
            "content": msg["content"]
        })

    # Add current user message
    messages.append({
        "role": "user",
        "content": user_message
    })

    try:
        response = openai_client.responses.create(
            model=OPENAI_MODEL,
            instructions=prompt(),
            input=messages,
            max_output_tokens=2000
        )

        return response.output_text

    except Exception as e:
        print(f"OpenAI error: {str(e)}")

        raise HTTPException(
            status_code=500,
            detail=f"OpenAI error: {str(e)}"
        )
    
@app.get("/")
async def root():
    return {
        "message": "AI Digital Twin API (Powered by AWS Bedrock)",
        "memory_enabled": True,
        "storage": "S3" if USE_S3 else "local",
        #"ai_model": BEDROCK_MODEL_ID
        "ai_model": OPENAI_MODEL
    }


@app.get("/health")
async def health_check():
    return {
        "status": "healthy", 
        "use_s3": USE_S3,
        #"bedrock_model": BEDROCK_MODEL_ID
        "ai_model": OPENAI_MODEL
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        # Generate session ID if not provided
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_conversation(session_id)

        # Call Bedrock for response
        #assistant_response = call_bedrock(conversation, request.message)
        assistant_response = call_openai(conversation, request.message)

        # Update conversation history
        conversation.append(
            {"role": "user", "content": request.message, "timestamp": datetime.now().isoformat()}
        )
        conversation.append(
            {
                "role": "assistant",
                "content": assistant_response,
                "timestamp": datetime.now().isoformat(),
            }
        )

        # Save conversation
        save_conversation(session_id, conversation)

        return ChatResponse(response=assistant_response, session_id=session_id)

    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in chat endpoint: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/conversation/{session_id}")
async def get_conversation(session_id: str):
    """Retrieve conversation history"""
    try:
        conversation = load_conversation(session_id)
        return {"session_id": session_id, "messages": conversation}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)