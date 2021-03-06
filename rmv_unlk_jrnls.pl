#!/usr/bin/perl
# 
# rmv_unlk_jrnls.pl - Removing journals from 30 issues that don't exist.
# 
# perl -ne "print if (! /1487,'Issue'/ && ! /^[^,]+,1540,'Issue'/ && ! /^[^,]+,1597,'Issue'/ && ! /^[^,]+,1683,'Issue'/ && ! /^[^,]+,1834,'Issue'/ && ! /^[^,]+,1999,'Issue'/
#  && ! /^[^,]+,2047,'Issue'/ && ! /^[^,]+,2128,'Issue'/ && ! /^[^,]+,2131,'Issue'/ && ! /^[^,]+,2371,'Issue'/ && ! /^[^,]+,2493,'Issue'/ && ! /^[^,]+,2831,'Issue'/ 
#  && ! /^[^,]+,3226,'Issue'/ && ! /^[^,]+,3586,'Issue'/ && ! /^[^,]+,3836,'Issue'/ && ! /^[^,]+,3956,'Issue'/ && ! /^[^,]+,4580,'Issue'/ && ! /^[^,]+,5063,'Issue'/
#  && ! /^[^,]+,5065,'Issue'/ && ! /^[^,]+,5436,'Issue'/ && ! /^[^,]+,5630,'Issue'/ && ! /^[^,]+,6184,'Issue'/ && ! /^[^,]+,6356,'Issue'/ && ! /^[^,]+,6557,'Issue'/ 
#  && ! /^[^,]+,6718,'Issue'/ && ! /^[^,]+,7262,'Issue'/ && ! /^[^,]+,7371,'Issue'/ && ! /^[^,]+,7401,'Issue'/ && ! /^[^,]+,7680,'Issue'/ && ! /^[^,]+,7764,'Issue'/ 
#  && ! /^[^,]+,8572,'Issue'/ && ! /^[^,]+,8751,'Issue'/ && ! /^[^,]+,8761,'Issue'/ && ! /^[^,]+,8762,'Issue'/ && ! /^[^,]+,8789,'Issue'/ && ! /^[^,]+,8792,'Issue'/ ) "

while(<>){
   print if (! /1487,'Issue'/ && ! /^[^,]+,1540,'Issue'/ && ! /^[^,]+,1597,'Issue'/ && ! /^[^,]+,1683,'Issue'/ && ! /^[^,]+,1834,'Issue'/ && ! /^[^,]+,1999,'Issue'/
   && ! /^[^,]+,2047,'Issue'/ && ! /^[^,]+,2128,'Issue'/ && ! /^[^,]+,2131,'Issue'/ && ! /^[^,]+,2371,'Issue'/ && ! /^[^,]+,2493,'Issue'/ && ! /^[^,]+,2831,'Issue'/ 
   && ! /^[^,]+,3226,'Issue'/ && ! /^[^,]+,3586,'Issue'/ && ! /^[^,]+,3836,'Issue'/ && ! /^[^,]+,3956,'Issue'/ && ! /^[^,]+,4580,'Issue'/ && ! /^[^,]+,5063,'Issue'/
   && ! /^[^,]+,5065,'Issue'/ && ! /^[^,]+,5436,'Issue'/ && ! /^[^,]+,5630,'Issue'/ && ! /^[^,]+,6184,'Issue'/ && ! /^[^,]+,6356,'Issue'/ && ! /^[^,]+,6557,'Issue'/ 
   && ! /^[^,]+,6718,'Issue'/ && ! /^[^,]+,7262,'Issue'/ && ! /^[^,]+,7371,'Issue'/ && ! /^[^,]+,7401,'Issue'/ && ! /^[^,]+,7680,'Issue'/ && ! /^[^,]+,7764,'Issue'/ 
   && ! /^[^,]+,8572,'Issue'/ && ! /^[^,]+,8751,'Issue'/ && ! /^[^,]+,8761,'Issue'/ && ! /^[^,]+,8762,'Issue'/ && ! /^[^,]+,8789,'Issue'/ && ! /^[^,]+,8792,'Issue'/ );

}
