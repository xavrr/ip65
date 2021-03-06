#include <cc65.h>
#include <time.h>
#include <fcntl.h>
#include <conio.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "../inc/ip65.h"

void error_exit(void)
{
  switch (ip65_error)
  {
  case IP65_ERROR_DEVICE_FAILURE:
    printf("- No device found\n");
    break;
  case IP65_ERROR_ABORTED_BY_USER:
    printf("- User abort\n");
    break;
  case IP65_ERROR_TIMEOUT_ON_RECEIVE:
    printf("- Timeout\n");
    break;
  case IP65_ERROR_DNS_LOOKUP_FAILED:
    printf("- Lookup failed\n");
    break;
  default:
    printf("- Error $%X\n", ip65_error);
  }
  exit(1);
}

void confirm_exit(void)
{
  printf("\nPress any key ");
  cgetc();
}

void main(void)
{
  unsigned long server, time;
  unsigned char drv_init = DRV_INIT_DEFAULT;

  if (doesclrscrafterexit())
  {
    atexit(confirm_exit);
  }

#ifdef __APPLE2__
  {
    int file;

    printf("\nSetting slot ");
    file = open("ethernet.slot", O_RDONLY);
    if (file != -1)
    {
      read(file, &drv_init, 1);
      close(file);
      drv_init &= ~'0';
    }
    printf("- %d\n", drv_init);
  }
#endif

  printf("\nInitializing ");
  if (ip65_init(drv_init))
  {
    error_exit();
  }

  printf("- Ok\n\nObtaining IP address ");
  if (dhcp_init())
  {
    error_exit();
  }

  printf("- Ok\n\nResolving pool.ntp.org ");
  server = dns_resolve("pool.ntp.org");
  if (!server)
  {
    error_exit();
  }

  printf("- Ok\n\nGetting UTC ");
  time = sntp_get_time(server);
  if (!time)
  {
    error_exit();
  }

  // Convert time from seconds since 1900 to
  // seconds since 1970 according to RFC 868.
  time -= 2208988800UL;

  printf("- %s", ctime(&time));
}
