import subprocess

interface = input("Interface >")
new_mac = input("New MAC >")

print(f"[+] Changing MAC address for {interface} with {new_mac}")

subprocess.call(["ifconfig", interface, "down"])
subprocess.call(["ifconfig", interface, "hw", "ether", new_mac])
subprocess.call(["ifconfig", interface, "up"])

