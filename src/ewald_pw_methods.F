!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief pw_methods
!> \author CJM
! **************************************************************************************************
MODULE ewald_pw_methods
   USE dg_rho0_types,                   ONLY: dg_rho0_get,&
                                              dg_rho0_init,&
                                              dg_rho0_set,&
                                              dg_rho0_type
   USE dg_types,                        ONLY: dg_get,&
                                              dg_type
   USE dgs,                             ONLY: dg_grid_change
   USE ewald_environment_types,         ONLY: ewald_env_get,&
                                              ewald_env_set,&
                                              ewald_environment_type
   USE ewald_pw_types,                  ONLY: ewald_pw_get,&
                                              ewald_pw_set,&
                                              ewald_pw_type
   USE input_section_types,             ONLY: section_vals_type
   USE kinds,                           ONLY: dp
   USE pw_grid_types,                   ONLY: pw_grid_type
   USE pw_grids,                        ONLY: pw_grid_change
   USE pw_poisson_methods,              ONLY: pw_poisson_set
   USE pw_poisson_read_input,           ONLY: pw_poisson_read_parameters
   USE pw_poisson_types,                ONLY: do_ewald_ewald,&
                                              do_ewald_none,&
                                              do_ewald_pme,&
                                              do_ewald_spme,&
                                              pw_poisson_parameter_type,&
                                              pw_poisson_type
   USE pw_pool_types,                   ONLY: pw_pool_p_type,&
                                              pw_pool_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'ewald_pw_methods'

   PUBLIC :: ewald_pw_grid_update

CONTAINS

! **************************************************************************************************
!> \brief Rescales pw_grids for given box, if necessary
!> \param ewald_pw ...
!> \param ewald_env ...
!> \param cell_hmat ...
!> \par History
!>      none
!> \author JGH (15-Mar-2001)
! **************************************************************************************************
   SUBROUTINE ewald_pw_grid_update(ewald_pw, ewald_env, cell_hmat)
      TYPE(ewald_pw_type), POINTER                       :: ewald_pw
      TYPE(ewald_environment_type), POINTER              :: ewald_env
      REAL(KIND=dp), DIMENSION(3, 3)                     :: cell_hmat

      INTEGER                                            :: ewald_type, o_spline
      REAL(dp)                                           :: alpha
      REAL(KIND=dp), DIMENSION(3, 3)                     :: old_cell_hmat
      TYPE(dg_type), POINTER                             :: dg
      TYPE(pw_poisson_parameter_type)                    :: poisson_params
      TYPE(pw_poisson_type), POINTER                     :: poisson_env
      TYPE(pw_pool_p_type), DIMENSION(:), POINTER        :: pw_pools
      TYPE(pw_pool_type), POINTER                        :: pw_big_pool, pw_small_pool
      TYPE(section_vals_type), POINTER                   :: poisson_section

      NULLIFY (pw_big_pool)
      NULLIFY (pw_small_pool)
      NULLIFY (dg, poisson_env, poisson_section)

      CALL ewald_env_get(ewald_env, ewald_type=ewald_type, &
                         alpha=alpha, o_spline=o_spline, &
                         poisson_section=poisson_section, &
                         cell_hmat=old_cell_hmat)

      IF (ALL(cell_hmat == old_cell_hmat)) RETURN ! rebuild not needed

      CALL ewald_env_set(ewald_env, cell_hmat=cell_hmat)

      SELECT CASE (ewald_type)
      CASE (do_ewald_ewald)
         CALL ewald_pw_get(ewald_pw, pw_big_pool=pw_big_pool, &
                           dg=dg, poisson_env=poisson_env)
         CALL pw_grid_change(cell_hmat, pw_big_pool%pw_grid)
         CALL ewald_pw_rho0_setup(ewald_env, pw_big_pool%pw_grid, dg)
         IF (ASSOCIATED(poisson_env)) THEN
            CALL poisson_env%release()
            DEALLOCATE (poisson_env)
            NULLIFY (poisson_env)
         END IF
         CALL ewald_pw_set(ewald_pw, pw_big_pool=pw_big_pool, &
                           poisson_env=poisson_env)
      CASE (do_ewald_pme)
         CALL ewald_pw_get(ewald_pw, pw_big_pool=pw_big_pool, &
                           pw_small_pool=pw_small_pool, dg=dg, &
                           poisson_env=poisson_env)
         IF (.NOT. ASSOCIATED(poisson_env)) THEN
            ALLOCATE (poisson_env)
            CALL poisson_env%create()
            CALL ewald_pw_set(ewald_pw, poisson_env=poisson_env)
         END IF
         CALL pw_grid_change(cell_hmat, pw_big_pool%pw_grid)
         CALL dg_grid_change(cell_hmat, pw_big_pool%pw_grid, pw_small_pool%pw_grid)
         CALL ewald_pw_rho0_setup(ewald_env, pw_small_pool%pw_grid, dg)
         CALL ewald_pw_set(ewald_pw, pw_big_pool=pw_big_pool, &
                           pw_small_pool=pw_small_pool, &
                           poisson_env=poisson_env)
      CASE (do_ewald_spme)
         CALL ewald_pw_get(ewald_pw, pw_big_pool=pw_big_pool, &
                           poisson_env=poisson_env)
         IF (.NOT. ASSOCIATED(poisson_env)) THEN
            ALLOCATE (poisson_env)
            CALL poisson_env%create()
         END IF
         CALL pw_grid_change(cell_hmat, pw_big_pool%pw_grid)
         CALL ewald_pw_set(ewald_pw, pw_big_pool=pw_big_pool, &
                           poisson_env=poisson_env)
      CASE (do_ewald_none)
      CASE default
         CPABORT("")
      END SELECT
      IF (ASSOCIATED(poisson_env)) THEN
         ALLOCATE (pw_pools(1))
         pw_pools(1)%pool => pw_big_pool
         CALL pw_poisson_read_parameters(poisson_section, poisson_params)
         poisson_params%ewald_type = ewald_type
         poisson_params%ewald_o_spline = o_spline
         poisson_params%ewald_alpha = alpha
         CALL pw_poisson_set(poisson_env, cell_hmat=cell_hmat, parameters=poisson_params, &
                             use_level=1, pw_pools=pw_pools)
         DEALLOCATE (pw_pools)
      END IF

   END SUBROUTINE ewald_pw_grid_update

! **************************************************************************************************
!> \brief Calculates the Fourier transform of the "Ewald function"
!> \param ewald_env ...
!> \param pw_grid ...
!> \param dg ...
!> \par History
!>      none
!> \author JGH (15-Mar-2001)
! **************************************************************************************************
   SUBROUTINE ewald_pw_rho0_setup(ewald_env, pw_grid, dg)
      TYPE(ewald_environment_type), POINTER              :: ewald_env
      TYPE(pw_grid_type), POINTER                        :: pw_grid
      TYPE(dg_type), POINTER                             :: dg

      INTEGER                                            :: ewald_type
      REAL(dp)                                           :: alpha
      REAL(dp), POINTER                                  :: gcc(:), zet(:)
      TYPE(dg_rho0_type), POINTER                        :: dg_rho0

      CALL ewald_env_get(ewald_env, alpha=alpha, ewald_type=ewald_type)
      CALL dg_get(dg, dg_rho0=dg_rho0)
      CALL dg_rho0_get(dg_rho0, gcc=gcc, zet=zet)

      IF (.NOT. ASSOCIATED(zet)) THEN
         ALLOCATE (zet(1))
      END IF

! No contracted Gaussians are used here
      NULLIFY (gcc)

      zet(1) = alpha
      CALL dg_rho0_set(dg_rho0, TYPE=ewald_type, zet=zet)

      CALL dg_rho0_init(dg_rho0, pw_grid)

   END SUBROUTINE ewald_pw_rho0_setup

END MODULE ewald_pw_methods

