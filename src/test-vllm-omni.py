#!/usr/bin/env python3
"""
Test script for vLLM-Omni Docker Serving Engine.
Supports LiteLLM (recommended) and falls back to direct requests if LiteLLM is not installed.

Usage:
    python3 src/test-vllm-omni.py [options]

Examples:
    # 1. Check server health & list models
    python3 src/test-vllm-omni.py --mode models

    # 2. Test Multimodal Vision Chat (e.g. Qwen3-Omni, MiniCPM-o)
    python3 src/test-vllm-omni.py --mode chat --model qwen3-omni

    # 3. Test Audio understanding
    python3 src/test-vllm-omni.py --mode audio --model minicpm-o

    # 4. Test Text-to-Image Diffusion (e.g. Qwen-Image)
    python3 src/test-vllm-omni.py --mode image --model qwen-image --prompt "A red panda in space"

    # 5. Run auto-detected test suite against whatever model is loaded
    python3 src/test-vllm-omni.py --mode all
"""

import argparse
import base64
import json
import os
import sys

try:
    import requests
except ImportError:
    print("Error: 'requests' library is required. Install via: pip install requests", file=sys.stderr)
    sys.exit(1)

# Check if LiteLLM is available
LITELLM_AVAILABLE = False
try:
    import litellm
    LITELLM_AVAILABLE = True
except ImportError:
    pass

DEFAULT_BASE_URL = "http://localhost:8091/v1"
SAMPLE_IMAGE_URL = (
    "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/"
    "Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
)
SAMPLE_AUDIO_URL = (
    "https://vllm-public-assets.s3.us-west-2.amazonaws.com/multimodal_asset/mary_had_lamb.ogg"
)


def get_available_models(base_url: str):
    """Query /v1/models to list active models."""
    url = f"{base_url.rstrip('/')}/models"
    try:
        resp = requests.get(url, timeout=10)
        resp.raise_for_status()
        data = resp.json()
        models = [m.get("id") for m in data.get("data", [])]
        return models
    except Exception as e:
        print(f"[!] Failed to connect to server at {url}: {e}", file=sys.stderr)
        return []


def test_models(base_url: str):
    """Test and print available models."""
    print(f"\n--- Checking Server Models ({base_url}/models) ---")
    models = get_available_models(base_url)
    if not models:
        print("[-] No models found or server is not reachable.")
        return None
    print(f"[+] Server is UP! Found {len(models)} model(s):")
    for m in models:
        print(f"    - {m}")
    return models[0]


def run_chat_completion(
    base_url: str,
    model: str,
    messages: list,
    use_litellm: bool = True,
):
    """Execute a chat completion request using LiteLLM or requests."""
    if use_litellm and LITELLM_AVAILABLE:
        print(f"[*] Executing via LiteLLM (model: openai/{model}) ...")
        # litellm expects 'openai/<model>' to route to OpenAI-compatible base URL
        litellm_model = f"openai/{model}"
        response = litellm.completion(
            model=litellm_model,
            api_base=base_url,
            api_key="none",
            messages=messages,
            temperature=0.7,
        )
        return response.choices[0].message.content
    else:
        if use_litellm and not LITELLM_AVAILABLE:
            print("[*] LiteLLM not installed. Falling back to HTTP requests.")
        url = f"{base_url.rstrip('/')}/chat/completions"
        payload = {
            "model": model,
            "messages": messages,
            "temperature": 0.7,
        }
        resp = requests.post(url, json=payload, timeout=60)
        resp.raise_for_status()
        result = resp.json()
        return result["choices"][0]["message"]["content"]


def test_vision_chat(base_url: str, model: str, prompt: str, image_url: str, use_litellm: bool):
    """Test multimodal vision chat."""
    print(f"\n--- Multimodal Vision Chat (Model: {model}) ---")
    print(f"Prompt: {prompt}")
    print(f"Image:  {image_url}")

    messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": image_url}},
            ],
        }
    ]
    try:
        reply = run_chat_completion(base_url, model, messages, use_litellm=use_litellm)
        print(f"\n[+] Vision Chat Response:\n{reply}\n")
        return True
    except Exception as e:
        print(f"[-] Vision Chat Failed: {e}", file=sys.stderr)
        return False


def test_audio_chat(base_url: str, model: str, prompt: str, audio_url: str, use_litellm: bool):
    """Test multimodal audio chat."""
    print(f"\n--- Multimodal Audio Understanding (Model: {model}) ---")
    print(f"Prompt: {prompt}")
    print(f"Audio:  {audio_url}")

    messages = [
        {
            "role": "user",
            "content": [
                {"type": "audio_url", "audio_url": {"url": audio_url}},
                {"type": "text", "text": prompt},
            ],
        }
    ]
    try:
        reply = run_chat_completion(base_url, model, messages, use_litellm=use_litellm)
        print(f"\n[+] Audio Chat Response:\n{reply}\n")
        return True
    except Exception as e:
        print(f"[-] Audio Chat Failed: {e}", file=sys.stderr)
        return False


def test_image_generation(base_url: str, model: str, prompt: str, output_path: str, use_litellm: bool):
    """Test text-to-image diffusion generation."""
    print(f"\n--- Text-to-Image Generation (Model: {model}) ---")
    print(f"Prompt: {prompt}")
    print(f"Output: {output_path}")

    try:
        if use_litellm and LITELLM_AVAILABLE:
            print(f"[*] Executing via LiteLLM (image_generation, model: openai/{model}) ...")
            response = litellm.image_generation(
                model=f"openai/{model}",
                api_base=base_url,
                api_key="none",
                prompt=prompt,
                size="1024x1024",
            )
            item = response.data[0]
            if hasattr(item, "b64_json") and item.b64_json:
                img_data = base64.b64decode(item.b64_json)
                with open(output_path, "wb") as f:
                    f.write(img_data)
                print(f"[+] Image successfully saved to {output_path}")
            elif hasattr(item, "url") and item.url:
                print(f"[+] Generated image URL: {item.url}")
            else:
                print(f"[+] Image response received: {item}")
        else:
            if use_litellm and not LITELLM_AVAILABLE:
                print("[*] LiteLLM not installed. Falling back to HTTP requests.")
            url = f"{base_url.rstrip('/')}/images/generations"
            payload = {
                "model": model,
                "prompt": prompt,
                "size": "1024x1024",
                "n": 1,
            }
            resp = requests.post(url, json=payload, timeout=120)
            resp.raise_for_status()
            data = resp.json()
            item = data["data"][0]
            if "b64_json" in item:
                img_data = base64.b64decode(item["b64_json"])
                with open(output_path, "wb") as f:
                    f.write(img_data)
                print(f"[+] Image successfully saved to {output_path}")
            elif "url" in item:
                print(f"[+] Generated image URL: {item['url']}")
            else:
                print(f"[+] Image response received: {item}")
        return True
    except Exception as e:
        print(f"[-] Image Generation Failed: {e}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Test vLLM-Omni Docker Serving Engine with LiteLLM and HTTP requests."
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_BASE_URL,
        help=f"vLLM-Omni API base URL (default: {DEFAULT_BASE_URL})",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Model ID or alias to query. If omitted, auto-detected from /v1/models.",
    )
    parser.add_argument(
        "--mode",
        choices=["models", "chat", "audio", "image", "all"],
        default="all",
        help="Test mode: models, chat (vision), audio, image (diffusion), or all (default: all)",
    )
    parser.add_argument(
        "--prompt",
        default=None,
        help="Custom prompt string for the test.",
    )
    parser.add_argument(
        "--image-url",
        default=SAMPLE_IMAGE_URL,
        help="Image URL for vision chat tests.",
    )
    parser.add_argument(
        "--audio-url",
        default=SAMPLE_AUDIO_URL,
        help="Audio URL for audio understanding tests.",
    )
    parser.add_argument(
        "--output",
        default="output.png",
        help="Output PNG file path for image generation (default: output.png)",
    )
    parser.add_argument(
        "--no-litellm",
        action="store_true",
        help="Bypass LiteLLM and use direct HTTP requests.",
    )

    args = parser.parse_args()
    use_litellm = (not args.no_litellm)

    print("=== vLLM-Omni Testing Tool ===")
    print(f"Target URL:        {args.url}")
    print(f"LiteLLM installed: {LITELLM_AVAILABLE}")
    print(f"LiteLLM mode:      {'Enabled' if use_litellm and LITELLM_AVAILABLE else 'Disabled / Direct HTTP'}")

    # Mode 1: List models only
    if args.mode == "models":
        test_models(args.url)
        return

    # Auto-resolve target model if not passed
    target_model = args.model
    if not target_model:
        models = get_available_models(args.url)
        if models:
            target_model = models[0]
            print(f"[+] Auto-detected active model: '{target_model}'")
        else:
            print("[-] Unable to detect models from server. Specify --model manually.", file=sys.stderr)
            sys.exit(1)

    # Determine actions based on mode
    model_lower = target_model.lower()

    if args.mode == "chat":
        prompt = args.prompt or "Describe the contents and colors in this image in detail:"
        test_vision_chat(args.url, target_model, prompt, args.image_url, use_litellm)

    elif args.mode == "audio":
        prompt = args.prompt or "Transcribe and summarize what is spoken in this audio clip:"
        test_audio_chat(args.url, target_model, prompt, args.audio_url, use_litellm)

    elif args.mode == "image":
        prompt = args.prompt or "A cinematic photo of a cute red panda wearing a spacesuit on Mars"
        test_image_generation(args.url, target_model, prompt, args.output, use_litellm)

    elif args.mode == "all":
        test_models(args.url)

        # Smart dispatch based on model name hints
        if "image" in model_lower and "omni" not in model_lower:
            # Diffusion model (e.g. Qwen-Image)
            prompt = args.prompt or "A serene mountain lake at sunrise with reflections in the water"
            test_image_generation(args.url, target_model, prompt, args.output, use_litellm)
        elif "tts" in model_lower or "audio" in model_lower:
            prompt = args.prompt or "Transcribe what is spoken in this audio:"
            test_audio_chat(args.url, target_model, prompt, args.audio_url, use_litellm)
        else:
            # Omni or vision model (e.g. Qwen3-Omni, MiniCPM-o)
            prompt = args.prompt or "Describe the contents and scenery of this image in 20 words:"
            test_vision_chat(args.url, target_model, prompt, args.image_url, use_litellm)


if __name__ == "__main__":
    main()
