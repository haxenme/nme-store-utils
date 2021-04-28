#include <stdio.h>

#include <openssl/objects.h>
#include <openssl/sha.h>
#include <openssl/x509.h>

int main(int argc, char **argv)
{
   printf("Hello\n");

   const char *cpath = "crap.cert";
   FILE *fp = fopen(cpath, "rb");
   if (!fp)
      return 0;
    
   PKCS7 *p7 = d2i_PKCS7_fp(fp, NULL);
   fclose(fp);

   PKCS7 *container = p7;

   const unsigned char *cert  = (unsigned char *)"12121";
   X509_STORE *store = X509_STORE_new();
   X509 *certificate = d2i_X509(NULL, &cert, (long)6);
   X509_STORE_add_cert(store, certificate);
   BIO *payload = BIO_new(BIO_s_mem());
   int result = PKCS7_verify(container, NULL, store, NULL, payload, 0);
   BIO_free(payload);

   return 0;
}
