/*
     PLIB - A Suite of Portable Game Libraries
     Copyright (C) 1998,2002  Steve Baker
 
     This library is free software; you can redistribute it and/or
     modify it under the terms of the GNU Library General Public
     License as published by the Free Software Foundation; either
     version 2 of the License, or (at your option) any later version.
 
     This library is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
     Library General Public License for more details.
 
     You should have received a copy of the GNU Library General Public
     License along with this library; if not, write to the Free Software
     Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
 
     For further information visit http://plib.sourceforge.net

     $Id: ssgSimpleState.cxx 2167 2012-08-14 17:24:50Z wolfram_kuss $
*/

void ssgSimpleState::apply (void)
{
  preApply () ;

  int turn_off = ~dont_care & ~enables & _ssgCurrentContext->getState()->enables & 0x3F ;
  (*(__ssgDisableTable[turn_off]))() ;
  _ssgCurrentContext->getState()->enables &= ~turn_off ;

  if ( ~ dont_care & ( (1<<SSG_GL_COLOR_MATERIAL_EN) |
                       (1<<SSG_GL_COLOR_MATERIAL   ) ) )
  {
    int indeterminate = turn_off & (1<<SSG_GL_COLOR_MATERIAL_EN) ;

    if ( ~ dont_care & (1<<SSG_GL_COLOR_MATERIAL ) &&
         _ssgCurrentContext->getState()->colour_material_mode != colour_material_mode )
    {
      glColorMaterial ( GL_FRONT_AND_BACK, (GLenum) colour_material_mode ) ;
      _ssgCurrentContext->getState()->colour_material_mode = colour_material_mode ;
      indeterminate |= _ssgCurrentContext->getState()->enables & (1<<SSG_GL_COLOR_MATERIAL_EN) ;
    }

    if ( indeterminate )
    {
      /* invalidate the material colours */
      sgSetVec3 ( _ssgCurrentContext->getState()->specular_colour, -1.0f, -1.0f, -1.0f ) ;
      sgSetVec3 ( _ssgCurrentContext->getState()->emission_colour, -1.0f, -1.0f, -1.0f ) ;
      sgSetVec3 ( _ssgCurrentContext->getState()->ambient_colour, -1.0f, -1.0f, -1.0f ) ;
      sgSetVec4 ( _ssgCurrentContext->getState()->diffuse_colour, -1.0f, -1.0f, -1.0f, -1.0f ) ;
    }
  }

  if ( ~ dont_care & ( (1<<SSG_GL_DIFFUSE       ) |
                       (1<<SSG_GL_AMBIENT       ) |
                       (1<<SSG_GL_SPECULAR      ) |
                       (1<<SSG_GL_EMISSION      ) |
                       (1<<SSG_GL_SHININESS     ) ) )
  {
    if ( ( ~ dont_care & (1<<SSG_GL_SHININESS) ) &&
      _ssgCurrentContext->getState()->shininess != shininess )
    {
      glMaterialf ( GL_FRONT_AND_BACK, GL_SHININESS, shininess ) ;
      _ssgCurrentContext->getState()->shininess = shininess ;
    }

    if ( ( ~ dont_care & (1<<SSG_GL_SPECULAR) ) &&
         ! sgEqualVec3 ( _ssgCurrentContext->getState()->specular_colour, specular_colour ) )
    {
      glMaterialfv ( GL_FRONT_AND_BACK, GL_SPECULAR, specular_colour ) ;
      sgCopyVec3 ( _ssgCurrentContext->getState()->specular_colour, specular_colour ) ;
    }

    if ( ( ~ dont_care & (1<<SSG_GL_EMISSION) ) &&
         ! sgEqualVec3 ( _ssgCurrentContext->getState()->emission_colour, emission_colour ) )
    {
      glMaterialfv ( GL_FRONT_AND_BACK, GL_EMISSION, emission_colour ) ;
      sgCopyVec3 ( _ssgCurrentContext->getState()->emission_colour, emission_colour ) ;
    }

    if ( ( ~ dont_care & (1<<SSG_GL_AMBIENT) ) &&
         ! sgEqualVec3 ( _ssgCurrentContext->getState()->ambient_colour, ambient_colour ) )
    {
      glMaterialfv ( GL_FRONT_AND_BACK, GL_AMBIENT, ambient_colour ) ;
      sgCopyVec3 ( _ssgCurrentContext->getState()->ambient_colour, ambient_colour ) ;
    }

    if ( ( ~ dont_care & (1<<SSG_GL_DIFFUSE) ) &&
         ! sgEqualVec4 ( _ssgCurrentContext->getState()->diffuse_colour, diffuse_colour ) )
    {
      glMaterialfv ( GL_FRONT_AND_BACK, GL_DIFFUSE, diffuse_colour ) ;
      sgCopyVec4 ( _ssgCurrentContext->getState()->diffuse_colour, diffuse_colour ) ;
    }
  }

  if ( ( ~ dont_care & (1<<SSG_GL_TEXTURE) ) && 
    _ssgCurrentContext->getState()->getTexture() != getTexture() )
  {
    stats_bind_textures++ ;
#ifdef GL_VERSION_1_1
    glBindTexture ( GL_TEXTURE_2D, getTextureHandle() ) ;
#else
    /* For ancient SGI machines */
    glBindTextureEXT ( GL_TEXTURE_2D, getTextureHandle() ) ;
#endif
    _ssgCurrentContext->getState()->setTexture ( getTexture () ) ;
  }

  if ( ( ~ dont_care & (1<<SSG_GL_SHADE_MODEL) ) &&
    _ssgCurrentContext->getState()->shade_model != shade_model )
  {
    glShadeModel ( shade_model ) ;
    _ssgCurrentContext->getState()->shade_model = shade_model ;
  }

  if ( ( ~ dont_care & (1<<SSG_GL_ALPHA_TEST) ) &&
    _ssgCurrentContext->getState()->alpha_clamp != alpha_clamp )
  {
    glAlphaFunc ( GL_GREATER, alpha_clamp ) ;
    _ssgCurrentContext->getState()->alpha_clamp = alpha_clamp ;
  }

  int turn_on = ~dont_care & enables & ~_ssgCurrentContext->getState()->enables & 0x3F ;
  (*(__ssgEnableTable [turn_on ]))() ;
  _ssgCurrentContext->getState()->enables |= turn_on ;

  preDraw () ;
}
