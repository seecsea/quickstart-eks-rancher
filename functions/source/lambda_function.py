from OpenSSL import crypto, SSL
import json
import boto3
import base64

client = boto3.client('ssm')

def cert_gen(
    emailAddress="emailAddress",
    commonName="ranchereksqs.awscloudbuilder.com",
    countryName="NT",
    localityName="localityName",
    stateOrProvinceName="stateOrProvinceName",
    organizationName="ranchereksqs.awscloudbuilder.com",
    organizationUnitName="organizationUnitName",
    serialNumber=0,
    validityStartInSeconds=0,
    validityEndInSeconds=365*24*60*60):

    # create a key pair
    k = crypto.PKey()
    k.generate_key(crypto.TYPE_RSA, 2048)
    # create a self-signed cert
    cert = crypto.X509()
    cert.get_subject().C = countryName
    cert.get_subject().ST = stateOrProvinceName
    cert.get_subject().L = localityName
    cert.get_subject().O = organizationName
    cert.get_subject().OU = organizationUnitName
    cert.get_subject().CN = commonName
    cert.get_subject().emailAddress = emailAddress
    cert.set_serial_number(serialNumber)
    cert.gmtime_adj_notBefore(0)
    cert.gmtime_adj_notAfter(validityEndInSeconds)
    cert.set_issuer(cert.get_subject())
    cert.set_pubkey(k)
    cert.sign(k, 'sha512')

    myCert=crypto.dump_certificate(crypto.FILETYPE_PEM, cert).decode("utf-8")
    myKey=crypto.dump_privatekey(crypto.FILETYPE_PEM, k).decode("utf-8")

    #Base64 conversion for k8 secrets string formatted
    myCert64=base64.b64encode(bytes(myCert, 'utf-8'))
    myKey64=base64.b64encode(bytes(myKey, 'utf-8'))

    #Decoded to string with bytes data removal for SSM class/string requirements
    myCert64_ssm=myCert64.decode("utf-8")
    myKey64_ssm=myKey64.decode("utf-8")

    # Write the cert nad key to SSM param store
    # /QS/Rancher/ELB/cert and /QS/Rancher/ELB/key
    # As Secure Strings
    response = client.put_parameter(
        Name='/QS/Rancher/ELB/cert',
        Description='Self-Signed SSL certificate',
        Value=myCert64_ssm,
        Type='SecureString',
        Overwrite=True
    )
    print ("/QS/Rancher/ELB/cert param response: ", response)

    response = client.put_parameter(
        Name='/QS/Rancher/ELB/key',
        Description='Self-Signed SSL certificate private key',
        Value=myKey64_ssm,
        Type='SecureString',
        Overwrite=True
    )
    print ("/QS/Rancher/ELB/key param response: ", response)


def lambda_handler(event, context):
    cert_gen()
    return {
        'statusCode': 200,
        'body': json.dumps('Self-Signed cert creation successful')
    }
