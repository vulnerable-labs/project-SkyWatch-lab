# Project SkyWatch - Comprehensive Solution Walkthrough

This document serves as an in-depth, educational guide to compromising the Project SkyWatch lab. It is designed to explain not just the "how," but the "why" behind each vulnerability in the attack chain. The lab demonstrates a realistic cloud-native exploitation path, ultimately leading to a root compromise.

## Phase 1: Initial Reconnaissance and Server-Side Request Forgery (SSRF)

### Core Concept: Server-Side Request Forgery (SSRF)
Server-Side Request Forgery is a vulnerability where an attacker forces a server to make network requests on their behalf. This occurs when an application accepts a URL (or similar input) from the user and fetches it without proper validation. Because the request originates from the server itself, it bypasses external firewalls and can interact with internal networks, local loopback interfaces, or cloud metadata endpoints that are otherwise hidden from the internet.

### Exploitation Step
1. Upon discovering the web application on port 80, navigate to the SkyWatch System Status dashboard.
2. At the bottom of the page, locate the "System Connect Checker (Admin Debug)" feature.
3. This feature allows administrators to test connectivity. Observe the network traffic when submitting a request. The application sends a GET request to an endpoint looking like:
   `/check?url=http://example.com`
4. To test if the application is fetching the URL blindly (an SSRF vulnerability), ask the server to fetch a resource on its own local loopback address:
   `http://<target_ip>/check?url=http://127.0.0.1:80`
5. The application returns the HTML of its own dashboard. This confirms the server is executing HTTP requests to the locations we specify. We now have our initial foothold to probe the internal environment.

## Phase 2: Cloud Metadata Exploitation

### Core Concept: Cloud Instance Metadata 
Major cloud providers (such as AWS, GCP, and Azure) provide a special, non-routable IP address (`169.254.169.254`) accessible only from within the virtual machine instance itself. This metadata service provides instances with configuration data, startup scripts, and critically, temporary security credentials for attached Identity and Access Management (IAM) roles. If an attacker achieves SSRF on a cloud instance, they can query this address to steal those credentials and impersonate the machine's assigned role.

### Exploitation Step
1. In the lab scenario, Project SkyWatch simulates a cloud-hosted environment. We can leverage the SSRF vulnerability to query the metadata service.
2. First, enumerate the IAM role attached to the instance by directing the SSRF to the credentials endpoint:
   `http://<target_ip>/check?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/`
3. The server responds with the name of the role: `web-server-role`.
4. Next, append the role name to the URL to retrieve the temporary credentials associated with that role:
   `http://<target_ip>/check?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/web-server-role`
5. The application will return a JSON object. You must extract three critical pieces of information from this response:
   - `AccessKeyId`
   - `SecretAccessKey`
   - `Token` (the session token validating the temporary credentials)

## Phase 3: Simulated Cloud Storage Enumeration

### Core Concept: Cross-Service IAM Abuse and S3 Enumeration
In cloud environments, obtaining IAM credentials rarely yields immediate shell access. Instead, the credentials grant permissions to other cloud services, such as object storage (Amazon S3), databases, or serverless functions. Attackers use these stolen credentials to enumerate assessable resources, searching for misconfigured backups, source code, or hardcoded secrets stored in cloud buckets.

### Exploitation Step
1. The dashboard's "Service Health" section contains a subtle hint: a service named "Backup Storage (Internal)" running at `http://127.0.0.1:8081`.
2. Given that we possess AWS IAM credentials, it is highly probable this internal service hosts an S3 storage bucket. We need to identify the bucket name. Standard cloud enumeration techniques involve guessing bucket names related to the company or application. 
3. The simulated bucket resides at `/nebula-monitoring-backups`. We can query it via our SSRF by appending the `AWSAccessKeyId` we stole as a query parameter (or by manually interacting with port 8081 if exposed, passing the keys in the headers):
   `http://<target_ip>/check?url=http://127.0.0.1:8081/nebula-monitoring-backups?AWSAccessKeyId=<Your_Stolen_Access_Key>`
4. The server returns an XML list (the standard S3 response format) revealing two files inside the bucket:
   - `monitor-admin_id_rsa`
   - `readme.txt`
5. Use the SSRF (or direct URL) to download both files by appending their names to the path.
6. Reading `readme.txt` reveals this is an emergency SSH key for the `monitor-admin` user.

## Phase 4: Horizontal Movement

### Core Concept: Identity Pivoting
Having extracted a private cryptographic key from the cloud storage bucket, we can pivot from interacting with web APIs and cloud infrastructure to obtaining direct command-line access on the underlying operating system. This transitions the attack from the application layer to the OS layer.

### Exploitation Step
1. On your attacker machine, copy the contents of `monitor-admin_id_rsa` into a new file.
2. SSH mandates strict permissions on private key files to prevent other users on your system from reading them. Secure the file:
   `chmod 600 monitor-admin_id_rsa`
3. Authenticate to the target machine using the private key:
   `ssh -i monitor-admin_id_rsa monitor-admin@<target_ip>`
4. Upon successful login, you have achieved user-level access. You can now read the first flag:
   `cat /home/monitor-admin/user.txt`

## Phase 5: Privilege Escalation via Linux Capabilities

### Core Concept: Linux Capabilities
Historically, Linux managed permissions using a binary model: you were either standard user or the superuser (root). To perform privileged actions (like binding a service to ports under 1024, or overriding file permissions), standard users required `sudo` access or SUID binaries (executables that run with root privileges regardless of who launches them). 
To improve security, Linux Capabilities were introduced to fragment root privileges. Instead of granting a binary full root power via SUID, an administrator can assign specific capabilities. For instance, `cap_net_bind_service` allows a binary to bind low ports without needing other root privileges. However, misassigning powerful capabilities can lead directly to full system compromise.

### Core Concept: cap_dac_override
The capability `cap_dac_override` stands for "Discretionary Access Control Override." It instructs the kernel to completely ignore all read, write, and execute permission checks for that process. If an attacker controls a binary with this capability, they can read or overwrite any file on the system, including critical system files like `/etc/shadow` or `/etc/passwd`.

### Exploitation Step
1. Now that you have shell access, begin local enumeration to find privilege escalation paths. Check for capabilities assigned to binaries recursively across the filesystem (redirecting errors to `/dev/null` for clean output):
   `getcap -r / 2>/dev/null`
2. The output reveals a custom monitoring binary:
   `/usr/bin/skywatch-agent = cap_dac_override+ep`
   (Note: `+ep` means the capability is Enabled and Permitted).
3. Investigate how the binary operates. Running `/usr/bin/skywatch-agent --help` or analyzing the binary with `strings` reveals that it reads a configuration file located at `~/.skywatch.conf` looking for a `[logging]` section to determine where it should write its logs.
4. Crucially, the `--test` flag accepts a user-provided string and writes it directly to the designated log file. Because the binary has `cap_dac_override`, it can append this text to *any* file on the system, bypassing all normal restrictions.
5. Create or edit the configuration file in the `monitor-admin` home directory to point the log path to the system's password file, which controls user authentication:
   ```ini
   # ~/.skywatch.conf
   [logging]
   path=/etc/passwd
   ```
6. The `/etc/passwd` file defines user accounts. By adhering to its standard format (`username:password_hash:UID:GID:Comment:HomePath:Shell`), an attacker can append a new user with a UID of 0 (which Linux recognizes as root). The password field "x" normally indicates the hash is in `/etc/shadow`, but putting a known hash or leaving it blank (if permitted) can allow login.
   To be stealthy and bypass password prompts, we can inject a line defining a new user `system-root` with no password requirement (by leaving the password field empty between the colons).
7. Execute the vulnerable binary, passing the payload as the test message:
   `/usr/bin/skywatch-agent --test "system-root::0:0:root:/root:/bin/bash"`
   *(This appends the string to `/etc/passwd`, registering `system-root` as an equivalent to the root user with no password).*
8. Switch to the newly created root-equivalent user:
   `su system-root`
9. Verification of privileges will show you are UID 0. You have completely compromised the machine.
10. Retrieve the final flag:
    `cat /root/root.txt`

## Summary
The Project SkyWatch attack path exemplifies the danger of compounding minor misconfigurations:
1. An unvalidated URL input (SSRF) exposed the internal network.
2. The SSRF allowed theft of excessively privileged IAM credentials from the cloud metadata service.
3. The stolen credentials unlocked sensitive backups in cloud storage.
4. Hardcoded emergency SSH keys in those backups granted horizontal movement to internal systems.
5. Finally, the over-assignment of Linux Capabilities (`cap_dac_override`) to a custom monitoring agent provided the arbitrary file write necessary to achieve complete system takeover.
